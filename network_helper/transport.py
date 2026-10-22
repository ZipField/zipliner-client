"""Game-only WinDivert TCP reflection and byte-preserving relay."""
import ipaddress
import ctypes
import os
import select
import socket
import threading
import time
import psutil
import pydivert
from pydivert import windivert_dll
from process_target import is_target
SERVER_PORT = 30000
HOLD_BUFFER_LIMIT = 1024 * 1024


def close_divert(network, on_error):
    """Wake a blocked receiver, then close even if receive shutdown fails."""
    if network is None or not network.is_open:
        return
    try:
        try:
            # WINDIVERT_SHUTDOWN_RECV = 0x1; zero is invalid (ERROR_INVALID_PARAMETER).
            windivert_dll.WinDivertShutdown(network._handle, 0x1)
        except OSError as error:
            on_error('shutdown_receive', error)
    finally:
        try:
            network.close()
        except OSError as error:
            on_error('close_handle', error)


def release_received_snapshot(source, decoder, on_receive=lambda data: None):
    """Forward cached bytes plus one snapshot of the socket queue, never future arrivals."""
    queued = ctypes.c_ulong()
    ioctlsocket = ctypes.WinDLL('ws2_32', use_last_error=True).ioctlsocket
    ioctlsocket.argtypes = [ctypes.c_size_t, ctypes.c_long, ctypes.POINTER(ctypes.c_ulong)]
    ioctlsocket.restype = ctypes.c_int
    if ioctlsocket(source.fileno(), 0x4004667f, ctypes.byref(queued)) != 0:
        raise OSError('Unable to snapshot the receive queue')
    remaining = queued.value
    output = bytearray(decoder.forward_snapshot())
    while remaining:
        data = source.recv(min(65536, remaining))
        if not data:
            break
        on_receive(data)
        remaining -= len(data)
        output.extend(decoder.forward_snapshot(data))
    return bytes(output)

def normalize(address):
    value = ipaddress.ip_address(address.split('%')[0])
    return str(value.ipv4_mapped or value) if value.version == 6 else str(value)


def pump_downstream(source, destination, decoder, stopping, on_forward=lambda size: None,
                    on_io=lambda event, fields: None, before_tick=lambda: b'',
                    on_receive=lambda data: None):
    """Socket relay separated from packet redirection for local integration testing."""
    last_data = time.monotonic()
    def send(data):
        if data:
            try:
                destination.sendall(data)
            except OSError as error:
                on_io('CLIENT_SEND_ERROR', {'winerror': getattr(error, 'winerror', None),
                                             'error': str(error)})
                raise
            on_forward(len(data))
    while not stopping():
        send(before_tick())
        send(decoder.tick())
        if decoder.holding:
            # Bounded read-ahead lets us observe a server EOF without forwarding bytes.
            remaining = HOLD_BUFFER_LIMIT - len(decoder.buffer)
            if remaining > 0:
                readable, _, _ = select.select([source], [], [], 0.1)
                if readable:
                    try:
                        data = source.recv(min(65536, remaining))
                    except OSError as error:
                        on_io('SERVER_RECV_ERROR', {'winerror': getattr(error, 'winerror', None),
                                                   'error': str(error)})
                        raise
                    if not data:
                        on_io('SERVER_EOF', {'during_hold': True})
                        return
                    on_receive(data)
                    send(decoder.feed(data))
                continue
            # Do not read later stream data during the hold; TCP supplies backpressure.
            time.sleep(0.02)
            continue
        try:
            readable, _, _ = select.select([source], [], [], 0.2)
        except OSError as error:
            on_io('SERVER_SELECT_ERROR', {'winerror': getattr(error, 'winerror', None), 'error': str(error)})
            raise
        if not readable:
            pending = decoder.release_if_off()
            if time.monotonic()-last_data > 2 and len(decoder.buffer) > decoder.forwarded:
                pending += decoder.abandon_partial('partial_candidate_timeout')
            send(pending)
            continue
        try:
            data = source.recv(65536)
        except OSError as error:
            on_io('SERVER_RECV_ERROR', {'winerror': getattr(error, 'winerror', None), 'error': str(error)})
            raise
        if not data:
            on_io('SERVER_EOF', {})
            send(decoder.finish())
            try:
                destination.shutdown(socket.SHUT_WR)
            except OSError as error:
                on_io('CLIENT_WRITE_SHUTDOWN_ERROR', {'winerror': getattr(error, 'winerror', None),
                                                      'error': str(error)})
            return
        last_data = time.monotonic()
        on_receive(data)
        send(decoder.feed(data))


def owner_is_game(packet, target='Endfield.exe'):
    """A diverted SYN leaves the OS socket available in the TCP ownership table."""
    wanted = (packet.src_addr, packet.src_port, packet.dst_addr, packet.dst_port)
    for attempt in range(3):
        for conn in psutil.net_connections(kind='tcp4'):
            if not conn.laddr or not conn.raddr:
                continue
            actual = (conn.laddr.ip, conn.laddr.port, conn.raddr.ip, conn.raddr.port)
            if actual == wanted:
                return conn.pid != os.getpid() and conn.pid is not None and is_target(conn.pid, target)
        if attempt < 2:
            time.sleep(0.02)
    return False


class Redirector:
    def __init__(self, port, is_game=owner_is_game, on_event=None):
        self.port, self.is_game = port, is_game
        self.on_event = on_event
        self.reported_syns = set()
        self.reported_unmatched_replies = set()
        self.lock = threading.RLock()
        self.routes = {}
        self.accepting_new = True

    def original(self, peer):
        with self.lock:
            route = self.routes.get((normalize(peer[0]), peer[1]))
            return route.copy() if route else None

    def pause_new_connections(self, established):
        """Let fresh game connections go direct; retain existing relay routes."""
        with self.lock:
            self.accepting_new = False
            self.routes = {key: route for key, route in self.routes.items()
                           if key in established}

    def resume_new_connections(self):
        with self.lock:
            self.accepting_new = True

    def rewrite(self, packet):
        if not packet.ipv4 or not packet.tcp or not packet.is_outbound:
            return False
        if packet.dst_port == SERVER_PORT:
            key = (packet.dst_addr, packet.src_port)
            with self.lock:
                route = self.routes.get(key)
            syn = packet.tcp.syn and not packet.tcp.ack
            is_game = False
            if syn and self.accepting_new:
                started = time.monotonic()
                is_game = self.is_game(packet)
                if self.on_event and key not in self.reported_syns:
                    if len(self.reported_syns) >= 1024:
                        self.reported_syns.clear()
                    self.reported_syns.add(key)
                    self.on_event('REDIRECT_SYN' if is_game else 'BYPASS_SYN',
                                  local=packet.src_addr, local_port=packet.src_port,
                                  remote=packet.dst_addr, remote_port=packet.dst_port,
                                  owner_verified=is_game,
                                  lookup_seconds=round(time.monotonic()-started, 3))
            if syn and self.accepting_new and is_game:
                route = {'local': packet.src_addr, 'remote': packet.dst_addr,
                         'client_port': packet.src_port, 'pid_verified': True}
                with self.lock:
                    # Disabling may have raced the ownership lookup above.
                    if self.accepting_new:
                        self.routes[key] = route
                    else:
                        route = self.routes.get(key)
            if not route or route['local'] != packet.src_addr:
                return False
            # Reflection from the official WinDivert streamdump topology.
            packet.src_addr, packet.dst_addr = packet.dst_addr, packet.src_addr
            packet.dst_port = self.port
            packet.direction = pydivert.Direction.INBOUND
            return True
        if packet.src_port == self.port:
            key = (packet.dst_addr, packet.dst_port)
            with self.lock:
                route = self.routes.get(key)
            if not route or route['local'] != packet.src_addr:
                if (self.on_event and (packet.tcp.syn or packet.tcp.rst)
                        and key not in self.reported_unmatched_replies):
                    if len(self.reported_unmatched_replies) >= 1024:
                        self.reported_unmatched_replies.clear()
                    self.reported_unmatched_replies.add(key)
                    self.on_event('PROXY_REPLY_UNMATCHED', source=[packet.src_addr, packet.src_port],
                                  destination=[packet.dst_addr, packet.dst_port],
                                  syn=bool(packet.tcp.syn), ack=bool(packet.tcp.ack),
                                  rst=bool(packet.tcp.rst))
                return False
            packet.src_addr, packet.dst_addr = packet.dst_addr, packet.src_addr
            packet.src_port = SERVER_PORT
            packet.direction = pydivert.Direction.INBOUND
            return True
        return False
