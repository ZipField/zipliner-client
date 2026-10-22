import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// One authenticated, local-only connection to a separate coordinate window.
/// The child reuses this executable in display-only mode; it never logs in.
class CoordinateWindowHost {
  CoordinateWindowHost({required this.onMessage, required this.onExit});
  final void Function(Map<String, dynamic>) onMessage;
  final void Function() onExit;
  ServerSocket? _server;
  Socket? _socket;
  Process? _process;
  final Set<Socket> _pending = {};
  bool _closed = false;
  final _ready = Completer<void>();

  Future<void> start(Map<String, dynamic> initialSnapshot) async {
    final secret = List.generate(
      32,
      (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final server = _server = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    server.listen((socket) {
      _pending.add(socket);
      var authenticated = false;
      final timer = Timer(const Duration(seconds: 5), () {
        if (!authenticated) socket.destroy();
      });
      socket
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
            (line) {
              try {
                if (line.length > 65536) {
                  throw const FormatException('Oversized message');
                }
                final message = jsonDecode(line) as Map<String, dynamic>;
                if (!authenticated) {
                  if (_socket != null ||
                      message['hello'] != secret ||
                      _closed) {
                    socket.destroy();
                    return;
                  }
                  authenticated = true;
                  timer.cancel();
                  _socket = socket;
                  send(initialSnapshot);
                  return;
                }
                if (message['event'] == 'ready' && !_ready.isCompleted) {
                  _ready.complete();
                }
                onMessage(message);
              } catch (_) {
                socket.destroy();
              }
            },
            onError: (Object error) {
              if (authenticated && !_ready.isCompleted) {
                _ready.completeError(error);
              }
            },
            onDone: () {
              timer.cancel();
              _pending.remove(socket);
              if (authenticated && !_closed) {
                if (!_ready.isCompleted) {
                  _ready.completeError(StateError('坐标窗口已退出'));
                }
                onExit();
              }
            },
          );
    });
    try {
      _process = await Process.start(
        Platform.resolvedExecutable,
        ['--coordinate-window', '${server.port}', secret, '$pid'],
        environment: {'ZIPLINER_WINDOW': '40,40,208,116'},
      );
      // Drain child output so inherited diagnostics cannot block its UI.
      unawaited(_process!.stdout.drain<void>());
      unawaited(_process!.stderr.drain<void>());
      unawaited(
        _process!.exitCode.then((_) {
          if (!_closed) {
            if (!_ready.isCompleted) {
              _ready.completeError(StateError('坐标窗口启动失败'));
            }
            onExit();
          }
        }),
      );
      await _ready.future.timeout(const Duration(seconds: 20));
    } catch (_) {
      await close();
      rethrow;
    }
  }

  void send(Map<String, dynamic> message) {
    if (!_closed && _socket != null) _socket!.write('${jsonEncode(message)}\n');
  }

  Future<void> close() async {
    if (_closed) return;
    send({'command': 'close'});
    _closed = true;
    final process = _process;
    if (process != null) {
      // Kill only our own display process if graceful shutdown stalls.
      unawaited(
        process.exitCode.timeout(
          const Duration(seconds: 2),
          onTimeout: () {
            process.kill();
            return -1;
          },
        ),
      );
    }
    _socket?.destroy();
    for (final socket in _pending.toList()) {
      socket.destroy();
    }
    await _server?.close();
  }
}
