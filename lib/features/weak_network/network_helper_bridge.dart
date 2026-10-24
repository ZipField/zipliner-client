import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';

import 'package:ffi/ffi.dart';

import 'package:zipliner_client/shared/logging/app_log.dart';

abstract interface class NetworkHelperBridge {
  Stream<Map<String, dynamic>> get events;
  Future<void> start();
  void send(Map<String, dynamic> command);
  Future<void> close();
}

class WindowsNetworkHelper implements NetworkHelperBridge {
  WindowsNetworkHelper(
    this.logDirectory, {
    this.targetExecutable = 'Endfield.exe',
  });
  final String logDirectory;
  final String targetExecutable;
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  final _ready = Completer<void>();
  final _shutdown = Completer<Map<String, dynamic>>();
  Future<void>? _closeFuture;
  ServerSocket? _server;
  Socket? _socket;
  bool _closed = false;
  int _processHandle = 0;
  int _launchedPid = 0;
  Timer? _processWatcher;
  late final _kernel = DynamicLibrary.open('kernel32.dll');
  final Set<Socket> _clients = {};

  @override
  Stream<Map<String, dynamic>> get events => _events.stream;

  @override
  Future<void> start() async {
    if (!Platform.isWindows) throw StateError('弱网功能目前仅支持 Windows。');
    final candidates = [
      File(
        '${File(Platform.resolvedExecutable).parent.path}/network/ZiplinerNetworkHelper.exe',
      ),
      File(
        '${Directory.current.path}/network_helper/dist/ZiplinerNetworkHelper/ZiplinerNetworkHelper.exe',
      ),
    ];
    final helper = candidates.where((f) => f.existsSync()).firstOrNull;
    if (helper == null) throw StateError('缺少网络辅助程序，请使用完整的 Windows 构建目录。');
    final random = Random.secure();
    final secret = List.generate(
      32,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final server = _server = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    server.listen((socket) => _accept(socket, secret), onError: _fail);
    final diagnostics =
        Platform.environment['ZIPLINER_NETWORK_DIAGNOSTICS'] == '1';
    final args =
        '--port ${server.port} --token $secret --log-directory "$logDirectory"'
        ' --target-executable "$targetExecutable"'
        '${diagnostics ? ' --diagnostic-log' : ''}';
    try {
      _elevate(helper.absolute.path, args);
      await _ready.future.timeout(
        const Duration(seconds: 60),
        onTimeout: () {
          throw StateError(
            '网络辅助程序未完成启动确认（PID=$_launchedPid）。请检查管理员授权和安全软件拦截记录。',
          );
        },
      );
    } catch (_) {
      try {
        await close();
      } catch (_) {
        /* Preserve the startup failure. */
      }
      rethrow;
    }
  }

  void _accept(Socket socket, String secret) {
    _clients.add(socket);
    var authenticated = false;
    final handshakeTimer = Timer(const Duration(seconds: 5), () {
      if (!authenticated) socket.destroy();
    });
    socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            if (line.length > 65536) {
              socket.destroy();
              return;
            }
            try {
              final message = jsonDecode(line);
              if (message is! Map<String, dynamic>) {
                throw const FormatException();
              }
              if (!authenticated) {
                if (_socket != null ||
                    message['hello'] != secret ||
                    message['pid'] != _launchedPid) {
                  socket.destroy();
                  return;
                }
                authenticated = true;
                handshakeTimer.cancel();
                _socket = socket;
                return;
              }
              if (message['event'] == 'ready' && !_ready.isCompleted) {
                if (message['pid'] != _launchedPid ||
                    message['elevated'] != true ||
                    message['admin_member'] != true ||
                    message['integrity_rid'] is! num ||
                    (message['integrity_rid'] as num) < 0x3000) {
                  _fail(
                    StateError('网络辅助程序未通过实际管理员权限确认，未开启弱网。请使用完整的最新版程序并重新授权。'),
                  );
                  return;
                }
                AppLog.instance.info(
                  '网络辅助程序已就绪：PID=$_launchedPid；exe=${message['executable']}；已提升=true；integrity=${message['integrity_rid']}',
                );
                _ready.complete();
              }
              if (message['event'] == 'shutdown_complete' &&
                  !_shutdown.isCompleted) {
                _shutdown.complete(message);
              }
              if (message['event'] == 'error' && !_ready.isCompleted) {
                _ready.completeError(
                  StateError(message['message']?.toString() ?? '网络辅助程序启动失败'),
                );
              }
              if (!_events.isClosed) _events.add(message);
            } catch (_) {
              socket.destroy();
            }
          },
          onError: (Object error) {
            if (authenticated) _fail(error);
          },
          onDone: () {
            handshakeTimer.cancel();
            _clients.remove(socket);
            if (authenticated && !_shutdown.isCompleted) {
              _shutdown.complete({
                'driver_unloaded': false,
                'message': '辅助程序已退出，但未确认驱动卸载。请重启电脑完成清理。',
              });
            }
            if (authenticated && !_closed) {
              _fail(StateError('网络辅助程序已断开，游戏将重新连接。'));
            }
          },
        );
  }

  void _fail(Object error) {
    if (_closed) return;
    if (!_ready.isCompleted) _ready.completeError(error);
    if (!_events.isClosed) {
      _events.add({'event': 'error', 'message': error.toString()});
    }
  }

  @override
  void send(Map<String, dynamic> command) {
    if (_socket == null || _closed) throw StateError('网络辅助程序尚未就绪');
    _socket!.write('${jsonEncode(command)}\n');
  }

  @override
  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    if (_closed) return;
    _closed = true;
    Object? failure;
    try {
      if (_socket != null) {
        _socket!.write('${jsonEncode({'command': 'shutdown'})}\n');
        await _socket!.flush().timeout(const Duration(seconds: 2));
        final result = await _shutdown.future.timeout(
          const Duration(seconds: 15),
        );
        if (result['driver_unloaded'] != true) {
          failure = StateError(
            result['message']?.toString() ?? '驱动卸载未完成，请重启电脑。',
          );
        }
      }
    } catch (error) {
      failure = error;
    } finally {
      _processWatcher?.cancel();
      for (final socket in _clients.toList()) {
        socket.destroy();
      }
      await _server?.close();
      await _events.close();
      if (_processHandle != 0) {
        _closeNativeHandle(_processHandle);
        _processHandle = 0;
      }
    }
    if (failure != null) throw failure;
  }

  void _closeNativeHandle(int handle) =>
      _kernel.lookupFunction<Int32 Function(IntPtr), int Function(int)>(
        'CloseHandle',
      )(handle);

  void _verifyLaunchedToken() {
    final api = DynamicLibrary.open('advapi32.dll');
    final openToken = api
        .lookupFunction<
          Int32 Function(IntPtr, Uint32, Pointer<IntPtr>),
          int Function(int, int, Pointer<IntPtr>)
        >('OpenProcessToken');
    final query = api
        .lookupFunction<
          Int32 Function(IntPtr, Int32, Pointer<Void>, Uint32, Pointer<Uint32>),
          int Function(int, int, Pointer<Void>, int, Pointer<Uint32>)
        >('GetTokenInformation');
    final token = calloc<IntPtr>();
    final elevated = calloc<Uint32>();
    final size = calloc<Uint32>();
    final lastError = _kernel.lookupFunction<Uint32 Function(), int Function()>(
      'GetLastError',
    );
    try {
      if (openToken(_processHandle, 0x8, token) == 0 ||
          query(token.value, 20, elevated.cast(), sizeOf<Uint32>(), size) ==
              0) {
        final code = lastError();
        throw StateError('无法确认网络辅助程序的实际提升权限（Windows错误码 $code），未开启弱网。');
      }
      if (elevated.value == 0) {
        throw StateError('网络辅助程序没有提升后的管理员权限，未开启弱网。');
      }
    } finally {
      if (token.value != 0) _closeNativeHandle(token.value);
      calloc.free(token);
      calloc.free(elevated);
      calloc.free(size);
    }
  }

  void _elevate(String path, String arguments) {
    final shellExecute = DynamicLibrary.open('shell32.dll')
        .lookupFunction<
          Int32 Function(Pointer<_ShellExecuteInfo>),
          int Function(Pointer<_ShellExecuteInfo>)
        >('ShellExecuteExW');
    final lastError = _kernel.lookupFunction<Uint32 Function(), int Function()>(
      'GetLastError',
    );
    final verb = 'runas'.toNativeUtf16();
    final file = path.toNativeUtf16();
    final args = arguments.toNativeUtf16();
    final info = calloc<_ShellExecuteInfo>();
    info.ref
      ..cbSize = sizeOf<_ShellExecuteInfo>()
      ..mask =
          0x140 // SEE_MASK_NOCLOSEPROCESS | SEE_MASK_NOASYNC.
      ..verb = verb
      ..file = file
      ..parameters = args
      ..show = 0;
    try {
      AppLog.instance.info('正在请求启动网络辅助程序：$path');
      if (shellExecute(info) == 0) {
        final code = lastError();
        throw StateError(
          code == 1223
              ? '未允许管理员授权，网络辅助程序未启动。'
              : '网络辅助程序启动失败（Windows错误码 $code）。',
        );
      }
      _processHandle = info.ref.process;
      if (_processHandle == 0) throw StateError('未取得网络辅助程序的进程句柄，未开启弱网。');
      _launchedPid = _kernel
          .lookupFunction<Uint32 Function(IntPtr), int Function(int)>(
            'GetProcessId',
          )(_processHandle);
      if (_launchedPid == 0) throw StateError('无法确认网络辅助程序的进程身份，未开启弱网。');
      _verifyLaunchedToken();
      AppLog.instance.info('网络辅助程序已启动：PID=$_launchedPid；实际已提升=true');
      final exitCode = _kernel
          .lookupFunction<
            Int32 Function(IntPtr, Pointer<Uint32>),
            int Function(int, Pointer<Uint32>)
          >('GetExitCodeProcess');
      _processWatcher = Timer.periodic(const Duration(milliseconds: 500), (_) {
        if (_closed || _processHandle == 0 || _shutdown.isCompleted) return;
        final code = calloc<Uint32>();
        try {
          if (exitCode(_processHandle, code) == 0) {
            _processWatcher?.cancel();
            _fail(StateError('无法查询网络辅助程序状态（PID=$_launchedPid）。'));
          } else if (code.value != 259) {
            // STILL_ACTIVE
            _processWatcher?.cancel();
            _fail(
              StateError('网络辅助程序已退出（PID=$_launchedPid，退出码=${code.value}）。'),
            );
          }
        } finally {
          calloc.free(code);
        }
      });
    } finally {
      calloc.free(info);
      calloc.free(verb);
      calloc.free(file);
      calloc.free(args);
    }
  }
}

final class _ShellExecuteInfo extends Struct {
  @Uint32()
  external int cbSize;
  @Uint32()
  external int mask;
  @IntPtr()
  external int window;
  external Pointer<Utf16> verb;
  external Pointer<Utf16> file;
  external Pointer<Utf16> parameters;
  external Pointer<Utf16> directory;
  @Int32()
  external int show;
  @IntPtr()
  external int instance;
  external Pointer<Void> idList;
  external Pointer<Utf16> className;
  @IntPtr()
  external int classKey;
  @Uint32()
  external int hotKey;
  @IntPtr()
  external int iconOrMonitor;
  @IntPtr()
  external int process;
}
