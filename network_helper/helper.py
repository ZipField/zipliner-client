"""Elevated helper entry point. Engine owns network and shutdown resources."""
import argparse
import os
import socket
import traceback

from engine import Engine

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--port', type=int, required=True)
    parser.add_argument('--token', required=True)
    parser.add_argument('--log-directory', required=True)
    parser.add_argument('--diagnostic-log', action='store_true')
    parser.add_argument('--target-executable', default='Endfield.exe')
    args = parser.parse_args()
    control = socket.create_connection(('127.0.0.1', args.port), timeout=10)
    engine = Engine(control, diagnostic_log=args.diagnostic_log, target_executable=args.target_executable)
    try:
        engine.send(hello=args.token, pid=os.getpid())
        engine.open(args.log_directory)
        engine.send(event='ready', **engine.identity)
        engine.log('HELPER_READY', pid=os.getpid())
        engine.run()
    except Exception as error:
        try:
            engine.log('ERROR', phase=engine.phase, error=str(error),
                       winerror=getattr(error, 'winerror', None), traceback=traceback.format_exc())
        except Exception:
            pass  # Preserve the original failure even if logging is unavailable.
        try:
            engine.send(event='error', message=str(error),
                        winerror=getattr(error, 'winerror', None), phase=engine.phase)
        except OSError:
            pass
    finally:
        try:
            engine.close()
        except Exception as error:
            engine.cleanup_error('helper', error)


if __name__ == '__main__':
    main()
