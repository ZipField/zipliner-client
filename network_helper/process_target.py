"""Match only the configured executable; never broaden to all processes."""
import os
import psutil


def is_target(pid, target='Endfield.exe'):
    try:
        path = os.path.normcase(os.path.abspath(psutil.Process(pid).exe()))
        if os.path.basename(target) == target:
            return os.path.basename(path).lower() == target.lower()
        return path == os.path.normcase(os.path.abspath(target))
    except (psutil.Error, OSError):
        return False
