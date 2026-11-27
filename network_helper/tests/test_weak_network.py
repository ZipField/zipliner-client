import unittest
import sys

from frame_stream import DownstreamFilter
from weak_state import WeakState


def frame(extra, length, marker=65):
    return bytes([extra]) + length.to_bytes(2, 'little') + bytes([marker]) * (extra+length)


class WeakNetworkTests(unittest.TestCase):
    def setUp(self):
        self.now = 0.0
        self.state = WeakState(lambda: self.now)
        self.events = []

    def decoder(self):
        def event(kind, fields):
            self.events.append((kind, fields))
            if kind == 'HOLD_FRAME':
                self.state.hold_started()
        return DownstreamFilter(self.state.active, event)

    def test_auto_snapshot_releases_entire_backlog_but_not_new_arrivals(self):
        self.state.enable(True)
        d = self.decoder()
        ordinary = frame(0, 2)
        target = frame(17, 4)
        backlog = target + ordinary + target
        self.assertEqual(d.feed(ordinary+backlog), ordinary)
        self.assertTrue(d.holding)
        self.state.release_all()
        self.assertEqual(d.forward_snapshot(), backlog)
        self.assertFalse(d.holding)
        self.assertEqual(d.feed(target), b'')
        self.assertTrue(d.holding)

    def test_automatic_deadline_releases_without_disabling(self):
        self.state.configure(10)
        self.state.enable(True)
        self.state.hold_started()
        self.now=10
        self.assertTrue(self.state.active())
        self.assertEqual(self.state.revision(),1)
        self.assertIsNone(self.state.started)
        self.now=11
        self.state.hold_started()
        self.assertEqual(self.state.snapshot()['remaining'],10)

    def test_release_restarts_deadline(self):
        self.state.configure(10)
        self.state.enable(True)
        self.state.hold_started()
        self.now=5
        self.state.release_all()
        self.state.hold_started()
        self.assertEqual(self.state.snapshot()['remaining'],10)
        self.now=10
        self.assertTrue(self.state.active())
        self.assertEqual(self.state.snapshot()['remaining'],5)
        self.now=15
        self.assertTrue(self.state.active())
        self.assertIsNone(self.state.started)
        self.assertEqual(self.state.revision(),2)

    def test_disable_returns_exact_original_bytes(self):
        self.state.enable(True)
        d=self.decoder()
        data=frame(17,4)+frame(0,5)
        self.assertEqual(d.feed(data),b'')
        self.state.enable(False)
        self.assertEqual(d.tick(),data)

    def test_snapshot_partial_frame_is_not_truncated_or_duplicated(self):
        self.state.enable(True)
        d=self.decoder()
        target=frame(17,4)
        following=frame(18,4,66)
        self.assertEqual(d.feed(target+following[:5]),b'')
        self.assertEqual(d.forward_snapshot(),target+following[:5])
        self.assertEqual(d.feed(following[5:]+target),following[5:])
        self.assertTrue(d.holding)

    def test_release_does_not_arm_future_data_if_backlog_empty(self):
        self.state.enable(True)
        d=self.decoder()
        self.state.release_all()
        self.assertEqual(d.forward_snapshot(),b'')
        self.assertEqual(d.feed(frame(17,4)),b'')
        self.assertTrue(d.holding)

    def test_maximum_range_is_enforced(self):
        for value in (0,9,31,float('nan'),True):
            with self.assertRaises(ValueError):self.state.configure(value)

    @unittest.skipUnless(sys.platform == 'win32', 'Winsock receive-queue snapshot')
    def test_snapshot_includes_kernel_backlog_but_not_later_frames(self):
        import select
        import socket
        from transport import release_received_snapshot
        self.state.enable(True)
        d=self.decoder()
        target=frame(17,4)
        ordinary=frame(0,3)
        self.assertEqual(d.feed(target),b'')
        source, writer=socket.socketpair()
        try:
            writer.sendall(ordinary+target)
            self.assertTrue(select.select([source],[],[],1)[0])
            self.assertEqual(release_received_snapshot(source,d),target+ordinary+target)
            writer.sendall(target)
            self.assertTrue(select.select([source],[],[],1)[0])
            self.assertEqual(d.feed(source.recv(65536)),b'')
            self.assertTrue(d.holding)
        finally:
            source.close()
            writer.close()


@unittest.skipUnless(sys.platform == 'win32', 'Windows network helper')
class RelaySummaryTests(unittest.TestCase):
    def test_disconnect_reports_first_eof_and_frame_progress(self):
        from concurrent.futures import ThreadPoolExecutor
        from contextlib import ExitStack
        import json
        from pathlib import Path
        import socket
        from tempfile import TemporaryDirectory
        from types import SimpleNamespace
        from unittest.mock import patch

        from engine import Engine
        from network_log import NetworkLog

        for first_eof, reply_length, reply_frames in (
            ('CLIENT_EOF', 3, 0),
            ('SERVER_EOF', 5, 1),
        ):
            with self.subTest(first_eof=first_eof), ExitStack() as stack:
                game, client = map(stack.enter_context, socket.socketpair())
                upstream, server = map(stack.enter_context, socket.socketpair())
                control, _ = map(stack.enter_context, socket.socketpair())
                root = stack.enter_context(TemporaryDirectory())
                engine = Engine(control)
                engine.logger = NetworkLog(root, engine.started)
                stack.callback(engine.logger.close)
                route = {'remote': '127.0.0.1', 'client_port': 12345}
                engine.redirector = SimpleNamespace(original=lambda peer: route)
                engine.state.enable(True)
                stack.enter_context(patch('engine.socket.create_connection', return_value=upstream))
                workers = stack.enter_context(ThreadPoolExecutor())
                relay = workers.submit(engine.connection, client, route)
                game.settimeout(3)
                server.settimeout(3)
                game_reader = stack.enter_context(game.makefile('rb'))
                server_reader = stack.enter_context(server.makefile('rb'))
                request = frame(0, 1)
                reply = frame(0, 2)[:reply_length]
                try:
                    game.sendall(request)
                    self.assertEqual(server_reader.read(len(request)), request)
                    server.sendall(reply)
                    self.assertEqual(game_reader.read(len(reply)), reply)
                    peer = game if first_eof == 'CLIENT_EOF' else server
                    peer.shutdown(socket.SHUT_WR)
                    relay.result(timeout=3)
                finally:
                    engine.stop.set()

                entries = [json.loads(line) for line in
                           (Path(root) / 'events.jsonl').read_text(encoding='utf-8').splitlines()]
                summary = entries[-1]
                self.assertEqual(summary['event'], 'DISCONNECTED')
                self.assertEqual(summary['first_end_event'], first_eof)
                self.assertFalse(summary['helper_stopping'])
                self.assertTrue(summary['upload_finished'])
                self.assertEqual(summary['dl_received_bytes'], len(reply))
                self.assertEqual(summary['dl_forwarded_bytes'], len(reply))
                self.assertEqual(summary['dl_frames'], reply_frames)
                self.assertEqual(summary['ul_received_bytes'], len(request))
                self.assertEqual(summary['ul_forwarded_bytes'], len(request))
                self.assertEqual(summary['ul_frames'], 1)
                self.assertFalse(any(event['event'] in {'UL_RECV', 'DL_RECV', 'DL_FORWARD'}
                                     for event in entries))


if __name__=='__main__':
    unittest.main()
