"""Elevated, authenticated loopback helper. No deletion or replacement commands."""
import ctypes
import hashlib
import json
import os
from pathlib import Path
import select
import socket
import threading
import time
import traceback

import pydivert

from frame_stream import DownstreamFilter
from transport import Redirector, owner_is_game, SERVER_PORT, pump_downstream, release_received_snapshot, close_divert
from weak_state import WeakState
from helper_hotkeys import HelperHotkeys
from game_connection import GameNetworkBlock, game_window_paths, game_tcp_snapshot
from coordinate_gate import PositionEvidence, ConnectionGate
from driver_service import unload_driver
from process_identity import process_identity
from network_log import NetworkLog

RECONNECT_WAIT_SECONDS = 5


class Engine:
    def __init__(self, control, diagnostic_log=False, target_executable='Endfield.exe'):
        self.target_executable = target_executable
        self.control = control
        self.state = WeakState()
        self.stop = threading.Event()
        self.lock = threading.RLock()
        self.write_lock = threading.Lock()
        self.connections = {}
        self.next_id = 0
        self.network = self.listener = self.redirector = None
        self.logger = None
        self.diagnostic_log = diagnostic_log
        self.started = time.monotonic()
        self.enabled_request_id = 0
        self.mutex = None
        self.positions = PositionEvidence()
        self.hotkeys = HelperHotkeys(self.hotkey_event)
        self.closing = False
        self.closed = False
        self.reconnecting = False
        self.reconnect_cancel = threading.Event()
        self.reconnect_worker = None
        self.reconnect_block = None
        self.reconnect_deadline = None
        self.reconnect_connected = threading.Event()
        self.game_paths = []
        self.last_window_check = 0
        self.phase = 'startup'
        self.driver_attempted = False
        self.divert_worker = None
        self.handshake_log_counts = {}
        self.identity = None

    def request_connection(self):
        # Recheck here: the UI's last status can be stale by the time it is clicked.
        with self.lock:
            if self.reconnect_deadline is not None and not self.reconnect_connected.is_set():
                self.send(event='reconnect', phase='waiting',
                          message='网络已恢复，正在等待游戏连接，请勿重复点击。')
                return
            if self.reconnecting or self.closing or self.connections:
                self.send(event='reconnect', phase='error', message='当前已连接或正在连接，请稍候。')
                return
        paths = game_window_paths(self.target_executable)
        if not paths:
            self.send(event='reconnect', phase='error', message='未找到游戏窗口，请先打开终末地。')
            return
        # Run on the control thread, serialized with ordinary enable commands.
        self.open_network()
        self.reconnecting = True
        self.reconnect_cancel.clear()
        self.reconnect_connected.clear()
        # An unsuccessful connection attempt must not leave a transparent relay
        # intercepting future game retries indefinitely. This survives worker errors.
        self.reconnect_deadline = time.monotonic() + 2 + RECONNECT_WAIT_SECONDS

        def reconnect():
            block = None
            failure = None
            try:
                # Prepare interception before the game creates a fresh connection.
                block = GameNetworkBlock()
                with self.lock:
                    self.reconnect_block = block
                if self.reconnect_cancel.is_set():
                    return
                self.log_game_connections('before_block', paths)
                if self.reconnect_cancel.is_set():
                    return
                block.open(paths)
                self.log('RECONNECT_BLOCK_STARTED', duration=2,
                         filter_ids=list(block.filter_ids))
                self.send(event='reconnect', phase='blocking')
                # Logging/control notifications cannot extend the actual lease.
                remaining = max(0, 2 - (time.monotonic() - block.committed_at))
                self.reconnect_cancel.wait(remaining)
            except Exception as error:
                failure = str(error)
                self.log('RECONNECT_FAILED', error=failure)
            finally:
                if block:
                    try:
                        block.close()
                    except Exception as error:
                        failure = str(error)
                        self.stop.set()
                        self.log('RECONNECT_CLEANUP_FAILED', error=failure,
                                 filter_ids=list(block.filter_ids))
                        # Keep the block reachable for Engine.close's retry.
                    else:
                        with self.lock:
                            if self.reconnect_block is block:
                                self.reconnect_block = None
                self.reconnecting = False
                if not self.closing and not self.stop.is_set():
                    try:
                        if failure:
                            self.send(event='reconnect', phase='error', message=failure)
                        else:
                            self.reconnect_deadline = (None if self.reconnect_cancel.is_set() else
                                                       time.monotonic() + RECONNECT_WAIT_SECONDS)
                            self.log('RECONNECT_NETWORK_RESTORED',
                                     elapsed=None if not block or block.committed_at is None else
                                     round(time.monotonic() - block.committed_at, 3),
                                     cancelled=self.reconnect_cancel.is_set())
                            self.send(event='reconnect', phase='restored')
                            self.log_game_connections('after_block', paths)
                    except OSError:
                        pass

        # This is deliberately separate from thread(): a failed request is not a
        # fatal keyboard-service error, and its filters must always be removed.
        self.reconnect_worker = threading.Thread(target=reconnect, daemon=True)
        self.reconnect_worker.start()

    def cancel_reconnect(self):
        self.reconnect_cancel.set()
        self.reconnect_deadline = None
        with self.lock:
            block = self.reconnect_block
        if block:
            try:
                block.close()
            except Exception as error:
                self.stop.set()
                self.log('RECONNECT_CLEANUP_FAILED', error=str(error),
                         filter_ids=list(block.filter_ids))

    def log_game_connections(self, phase, paths):
        try:
            self.log('GAME_TCP_SNAPSHOT', phase=phase, connections=game_tcp_snapshot(paths))
        except Exception as error:
            self.log('GAME_TCP_SNAPSHOT_FAILED', phase=phase, error=str(error))

    def check_reconnect_timeout(self):
        deadline = self.reconnect_deadline
        if deadline is None or self.reconnect_connected.is_set() or time.monotonic() < deadline:
            return
        self.reconnect_deadline = None
        self.state.enable(False)
        self.stop.set()
        self.cancel_reconnect()
        self.log('RECONNECT_CONNECT_TIMEOUT', intercepted_connections=len(self.connections))
        self.send(event='error', phase='reconnect_timeout',
                  message='连接游戏超时，正在停止网络接管并恢复直连。请重新进入游戏后再试。')

    def hotkey_event(self, action, revision):
        if self.closing or self.stop.is_set():
            return
        self.log('HOTKEY', action=action, hotkey_revision=revision)
        self.send(event='hotkey', action=action, hotkey_revision=revision)

    def send(self, **fields):
        data = (json.dumps(fields, ensure_ascii=True) + '\n').encode()
        with self.write_lock:
            self.control.sendall(data)

    def log(self, event, **fields):
        if self.logger:
            self.logger.write(event, **fields)

    def open(self, log_directory):
        root = Path(log_directory) / 'network_logs' / time.strftime('%Y%m%d_%H%M%S')
        root.mkdir(parents=True, exist_ok=True)
        self.logger = NetworkLog(root, self.started, self.diagnostic_log)
        self.log('HELPER_STARTED', pid=os.getpid(), diagnostic_log=self.diagnostic_log)
        self.phase = 'permissions'
        self.identity = process_identity()
        self.log('HELPER_IDENTITY', **self.identity)
        if (not self.identity['elevated'] or self.identity['integrity_rid'] < 0x3000
                or not self.identity['admin_member']):
            raise PermissionError('网络辅助程序未获得提升后的管理员权限，未开启弱网。请重新开启并允许管理员授权。')
        kernel = ctypes.WinDLL('kernel32', use_last_error=True)
        kernel.CreateMutexW.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_wchar_p]
        kernel.CreateMutexW.restype = ctypes.c_void_p
        kernel.CloseHandle.argtypes = [ctypes.c_void_p]
        self.mutex = kernel.CreateMutexW(None, False, 'Local\\EndfieldTrafficHotkeys')
        if not self.mutex:
            raise ctypes.WinError(ctypes.get_last_error())
        if ctypes.get_last_error() == 183:
            kernel.CloseHandle(self.mutex)
            self.mutex = None
            raise RuntimeError('旧弱网工具仍在运行，请先退出旧工具后再开启。')
        self.thread(lambda: self.hotkeys.run(self.stop))

    def open_network(self):
        if self.network is not None:
            self.redirector.resume_new_connections()
            return
        self.phase = 'relay_listener'
        self.listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.listener.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
        self.listener.bind(('0.0.0.0', 0))
        self.listener.listen(16)
        self.listener.settimeout(0.2)
        port = self.listener.getsockname()[1]
        self.log('LISTENER_OPENED', address='0.0.0.0', port=port,
                 backlog=16, server_port=SERVER_PORT)
        self.redirector = Redirector(port, is_game=lambda packet: owner_is_game(packet, self.target_executable), on_event=lambda event, **fields: self.log(event, **fields))
        self.phase = 'driver_files'
        from pydivert import windivert_dll
        dll_path = Path(windivert_dll.DLL_PATH)
        driver_path = dll_path.with_name('WinDivert64.sys')
        def file_info(path):
            try:
                stat = path.stat()
                return {'path': str(path), 'exists': True, 'bytes': stat.st_size}
            except OSError as error:
                return {'path': str(path), 'exists': False,
                        'winerror': getattr(error, 'winerror', None), 'error': str(error)}
        self.log('DRIVER_FILES', dll=file_info(dll_path), driver=file_info(driver_path))
        self.phase = 'driver_open'
        self.driver_attempted = True
        self.log('DRIVER_OPEN_STARTED')
        self.network = pydivert.WinDivert(
            f'outbound and ip and tcp and (tcp.DstPort == {SERVER_PORT} or tcp.SrcPort == {port})',
            priority=123)
        try:
            self.network.open()
        except Exception as error:
            self.log('DRIVER_OPEN_FAILED', winerror=getattr(error, 'winerror', None),
                     error=str(error), traceback=traceback.format_exc(),
                     dll=file_info(dll_path), driver=file_info(driver_path))
            raise
        self.log('DRIVER_OPENED')
        self.phase = 'running'
        self.thread(self.accept)
        self.divert_worker = self.thread(self.divert)

    def standby(self):
        """Keep the elevated keyboard service; stop holds and new redirection."""
        self.cancel_reconnect()
        self.state.enable(False)
        with self.lock:
            established = {(c['route']['remote'], c['route']['client_port'])
                           for c in self.connections.values() if c['established']}
            if self.redirector:
                self.redirector.pause_new_connections(established)
            pending = [sock for c in self.connections.values() if not c['established']
                       for sock in c['sockets']]
        # Existing connected relays forward the original bytes without holding;
        # incomplete attempts must not continue to trap game connection retries.
        for sock in pending:
            try:
                sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
        self.log('HELPER_STANDBY', established=len(established))

    def thread(self, function):
        def run():
            try:
                function()
            except Exception as error:
                if not self.closing and not self.stop.is_set():
                    self.log('ERROR', phase=self.phase, error=str(error),
                             winerror=getattr(error, 'winerror', None), traceback=traceback.format_exc())
                    try:
                        self.send(event='error', message=str(error),
                                  winerror=getattr(error, 'winerror', None), phase=self.phase)
                    except OSError:
                        pass
                    self.stop.set()
        thread = threading.Thread(target=run, daemon=True)
        thread.start()
        return thread

    def divert(self):
        while not self.stop.is_set():
            packet = self.network.recv()
            changed = self.redirector.rewrite(packet)
            sent = self.network.send(packet)
            if changed and packet.tcp and (packet.tcp.syn or packet.tcp.rst):
                hop = 'game_to_proxy' if packet.dst_port == self.redirector.port else 'proxy_to_game'
                key = (hop, packet.src_addr, packet.src_port, packet.dst_addr,
                       packet.dst_port, bool(packet.tcp.syn), bool(packet.tcp.ack), bool(packet.tcp.rst))
                count = self.handshake_log_counts.get(key, 0)
                if count < 3:
                    if len(self.handshake_log_counts) >= 1024:
                        self.handshake_log_counts.clear()
                    self.handshake_log_counts[key] = count + 1
                    self.log('REFLECT_INJECTED', hop=hop, attempt=count+1,
                             source=[packet.src_addr, packet.src_port],
                             destination=[packet.dst_addr, packet.dst_port],
                             syn=bool(packet.tcp.syn), ack=bool(packet.tcp.ack),
                             rst=bool(packet.tcp.rst), sent_bytes=sent)

    def accept(self):
        while not self.stop.is_set():
            try:
                client, peer = self.listener.accept()
            except socket.timeout:
                continue
            self.log('PROXY_ACCEPTED', peer=list(peer))
            route = self.redirector.original(peer)
            if route is None:
                self.log('PROXY_ROUTE_MISSING', peer=list(peer))
                client.close()
                continue
            self.log('PROXY_ROUTE_MATCHED', peer=list(peer), remote=route['remote'],
                     client_port=route['client_port'])
            self.thread(lambda c=client, r=route: self.connection(c, r))

    def connection(self, client, route):
        upstream = None
        ended = threading.Event()
        with self.lock:
            # A disable can retire a route between accept() and this worker.
            if self.redirector.original((route['remote'], route['client_port'])) is None:
                client.close()
                return
            self.next_id += 1
            ident = self.next_id
            self.connections[ident] = {'holding': False, 'established': False,
                                       'route': route, 'sockets': [client]}
        def close_direction(sock):
            try:
                sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
        try:
            self.log('UPSTREAM_CONNECT_STARTED', connection=ident,
                     remote=route['remote'], remote_port=SERVER_PORT)
            upstream = socket.create_connection((route['remote'], SERVER_PORT), timeout=10)
            upstream.settimeout(10)
            client.settimeout(10)
            for sock in (client, upstream):
                sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            with self.lock:
                if self.redirector.original((route['remote'], route['client_port'])) is None:
                    return
                self.connections[ident]['sockets'].append(upstream)
                self.connections[ident]['established'] = True
            self.log('CONNECTED', connection=ident)
            self.reconnect_connected.set()
            self.reconnect_deadline = None
            gate = ConnectionGate(self.state, self.positions,
                                  lambda event, **fields: self.log(event, connection=ident, **fields))
            def frame_event(event, fields):
                self.log(event, direction='DL', connection=ident, **fields)
                if event == 'PASS_FRAME':
                    gate.forwarded(fields['index'])
                with self.lock:
                    if event in ('HOLD_FRAME', 'HOLD_CANCELLED'):
                        self.connections[ident]['holding'] = event == 'HOLD_FRAME'
                if event == 'HOLD_FRAME':
                    self.state.hold_started()
                    gate.hold_started(fields)
                elif event == 'HOLD_CANCELLED':
                    gate.hold_ended()
                    if gate.bypass(fields['index']):
                        self.state.region_exited()
                elif event == 'PARSER_DISABLED':
                    self.state.enable(False)
                    self.send(event='error', message='当前连接的数据格式未能识别，已停止弱网。请重新连接后再试。')
            def observe_frame(fields):
                return gate.observe(fields)

            download_received_seconds = None

            def download_raw_frame(fields):
                self.log('DL_FRAME_BYTES', direction='DL', connection=ident,
                         received_seconds=download_received_seconds, **fields)

            decoder = DownstreamFilter(self.state.active, frame_event,
                                       frame_observer=observe_frame,
                                       raw_frame_event=download_raw_frame if self.diagnostic_log else None,
                                       bypass_frame=gate.bypass,
                                       trace_payload=self.diagnostic_log)
            download_offset = 0
            forwarded_offset = 0

            def capture_download(data):
                nonlocal download_offset, download_received_seconds
                if not self.diagnostic_log:
                    return
                # Called once for every socket read, including bounded hold
                # read-ahead and manual release reads. Never log cached bytes twice.
                download_received_seconds = round(time.monotonic()-self.started, 6)
                self.log('DL_RECV', direction='DL', connection=ident,
                         received_seconds=download_received_seconds,
                         stream_offset=download_offset, payload_bytes=len(data),
                         holding=decoder.holding,
                         sha256=hashlib.sha256(data).hexdigest())
                download_offset += len(data)

            def download_forwarded(size):
                nonlocal forwarded_offset
                if not self.diagnostic_log:
                    return
                self.log('DL_FORWARD', direction='DL', connection=ident,
                         forwarded_seconds=round(time.monotonic()-self.started, 6),
                         stream_offset=forwarded_offset, payload_bytes=size)
                forwarded_offset += size

            revision = self.state.revision()
            def release_snapshot():
                nonlocal revision
                position_release = gate.tick(decoder)
                current = self.state.revision()
                if current == revision and not position_release:
                    return b''
                revision = current
                if position_release:
                    decoder.cancel_hold('normal_position_confirmed')
                output = release_received_snapshot(upstream, decoder,
                                                   on_receive=capture_download)
                self.log('RELEASE_SNAPSHOT', connection=ident, bytes=len(output), revision=current,
                         reason='normal_position_confirmed' if position_release else 'release_request')
                return output
            def upload():
                received_seconds = None
                stream_offset = 0

                def upload_event(event, fields):
                    # Capture-only parser: its errors never disable weak networking.
                    self.log('UL_' + event, direction='UL', connection=ident,
                             received_seconds=received_seconds, **fields)
                    if event == 'PASS_FRAME':
                        gate.upload_frame(fields)

                def upload_raw_frame(fields):
                    self.log('UL_FRAME_BYTES', direction='UL', connection=ident,
                             received_seconds=received_seconds, **fields)

                # Never use parser output for forwarding. TCP receive boundaries
                # are logged as summaries. Raw capture is restricted to complete
                # xx0400/xx0000 frames, and never changes outgoing bytes.
                upload_decoder = DownstreamFilter(lambda: False, upload_event,
                                                  raw_frame_event=upload_raw_frame if self.diagnostic_log else None,
                                                  trace_payload=self.diagnostic_log)
                try:
                    while not self.stop.is_set() and not ended.is_set():
                        ready, _, _ = select.select([client], [], [], 0.2)
                        if not ready:
                            continue
                        data = client.recv(65536)
                        if not data:
                            upload_decoder.finish()
                            break
                        received_seconds = round(time.monotonic()-self.started, 6)
                        if self.diagnostic_log:
                            self.log('UL_RECV', direction='UL', connection=ident,
                                     received_seconds=received_seconds,
                                     stream_offset=stream_offset, payload_bytes=len(data),
                                     sha256=hashlib.sha256(data).hexdigest())
                        stream_offset += len(data)
                        # Arm any menu allowance before forwarding its request,
                        # so a fast server response cannot overtake the allowance.
                        upload_decoder.feed(data)
                        upstream.sendall(data)
                except OSError:
                    pass
                finally:
                    ended.set()
                    close_direction(upstream)
            uploader = threading.Thread(target=upload, daemon=True)
            uploader.start()
            try:
                pump_downstream(upstream, client, decoder,
                                lambda: self.stop.is_set() or ended.is_set(),
                                before_tick=release_snapshot,
                                on_receive=capture_download,
                                on_forward=download_forwarded,
                                on_io=lambda event, fields: self.log(
                                    event, direction='DL', connection=ident, **fields))
            except OSError as error:
                self.log('CONNECTION_ENDED', connection=ident, error=str(error))
            finally:
                ended.set()
                close_direction(client)
                close_direction(upstream)
                uploader.join(timeout=1)
        except OSError as error:
            self.log('CONNECT_FAILED', connection=ident, error=str(error),
                     winerror=getattr(error, 'winerror', None), remote=route['remote'])
        finally:
            for sock in (client, upstream):
                if sock:
                    sock.close()
            with self.lock:
                self.connections.pop(ident, None)
            self.log('DISCONNECTED', connection=ident)

    def run(self):
        self.control.settimeout(0.1)
        pending = b''
        last_status = 0
        while not self.stop.is_set():
            try:
                data = self.control.recv(16384)
                if not data:
                    return
                pending += data
                if len(pending) > 65536:
                    raise ValueError('Control message too large')
                while b'\n' in pending:
                    line, pending = pending.split(b'\n', 1)
                    cmd = json.loads(line)
                    kind = cmd.get('command')
                    if kind == 'configure':
                        self.hotkeys.configure(cmd['hotkeys'], cmd['hotkeys_suspended'], cmd['hotkey_revision'])
                        self.state.configure(cmd['maximum'])
                    elif kind == 'enable':
                        if cmd['enabled'] is True:
                            self.open_network()
                            self.state.enable(True)
                        else:
                            self.standby()
                        self.enabled_request_id = int(cmd.get('request_id', 0))
                    elif kind == 'release_all':
                        self.cancel_reconnect()
                        self.state.release_all()
                    elif kind == 'position':
                        self.positions.update(cmd['sample'])
                    elif kind == 'reconnect':
                        try:
                            self.request_connection()
                        except Exception as error:
                            self.send(event='reconnect', phase='error', message=str(error))
                    elif kind == 'shutdown':
                        return
                    else:
                        raise ValueError('Unknown command')
                    if kind != 'position':
                        self.log('CONTROL', **cmd)
            except socket.timeout:
                pass
            self.check_reconnect_timeout()
            self.state.tick()
            now = time.monotonic()
            if now - last_status >= 0.2:
                last_status = now
                with self.lock:
                    holding = sum(c['holding'] for c in self.connections.values())
                    active = len(self.connections)
                if now - self.last_window_check >= 0.5:
                    self.last_window_check = now
                    self.game_paths = game_window_paths(self.target_executable)
                self.send(event='state', active=active, holding=holding,
                          game_window_found=bool(self.game_paths),
                          enabled_request_id=self.enabled_request_id, **self.state.snapshot())

    def cleanup_error(self, step, error):
        # Cleanup diagnostics must never prevent the remaining resources closing.
        try:
            self.log('CLEANUP_ERROR', step=step, error=str(error))
        except Exception:
            pass

    def cleanup(self, step, action):
        try:
            action()
        except Exception as error:
            self.cleanup_error(step, error)

    def close(self):
        with self.lock:
            if self.closed:
                return
            self.closed = self.closing = True
        self.cancel_reconnect()
        if self.reconnect_worker:
            self.cleanup('reconnect_worker', lambda: self.reconnect_worker.join(timeout=3))
        with self.lock:
            block = self.reconnect_block
        if block:
            self.cleanup('reconnect_block', block.close)
        # Release original bytes before dismantling the relay; no cross-connection replay.
        self.state.enable(False)
        if self.redirector:
            self.redirector.accepting_new = False
        time.sleep(0.6)
        self.stop.set()
        with self.lock:
            for connection in list(self.connections.values()):
                for sock in connection['sockets']:
                    try:
                        sock.shutdown(socket.SHUT_RDWR)
                    except OSError:
                        pass
        if self.listener:
            self.cleanup('listener', self.listener.close)
        self.cleanup('redirector', lambda: close_divert(self.network, self.cleanup_error))
        if self.divert_worker:
            self.cleanup('receiver', lambda: self.divert_worker.join(timeout=2))
        driver_error = None
        if self.driver_attempted:
            try:
                unload_driver(self.log)
            except Exception as error:
                driver_error = str(error)
                self.cleanup_error('driver_unload', error)
        try:
            self.send(event='shutdown_complete', driver_unloaded=driver_error is None,
                      message=driver_error)
        except OSError:
            pass  # Parent exit still runs this cleanup on control-socket EOF.
        # Daemon connection workers may still finish logging during interpreter exit.
        self.cleanup('control', self.control.close)
        if self.mutex:
            def close_mutex():
                kernel = ctypes.WinDLL('kernel32', use_last_error=True)
                kernel.CloseHandle.argtypes = [ctypes.c_void_p]
                kernel.CloseHandle(self.mutex)
                self.mutex = None
            self.cleanup('mutex', close_mutex)
        if self.logger:
            self.logger.close()
