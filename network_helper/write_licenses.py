"""Collect redistribution notices from the pinned build dependencies."""
from importlib import metadata
from pathlib import Path
import shutil
import sys


def main():
    destination = Path(__file__).parent/'dist'
    licenses = destination/'licenses'
    licenses.mkdir(parents=True, exist_ok=True)
    for name in ('pydivert', 'psutil', 'pyinstaller'):
        distribution = metadata.distribution(name)
        for relative in distribution.files or []:
            if any(word in relative.name.lower() for word in ('license', 'copying', 'notice')):
                source = distribution.locate_file(relative)
                if source.is_file():
                    shutil.copyfile(source, licenses/f'{name}-{relative.name}')
    python_license = Path(sys.base_prefix)/'LICENSE.txt'
    if python_license.exists():
        shutil.copyfile(python_license, licenses/'Python-LICENSE.txt')
    (destination/'THIRD_PARTY.txt').write_text(
        'pydivert 3.1.3: https://github.com/ffalcinelli/pydivert\n'
        'WinDivert 2.2.2 (bundled by pydivert): https://github.com/basil00/WinDivert/tree/v2.2.2\n'
        'psutil 7.0.0: https://github.com/giampaolo/psutil/tree/release-7.0.0\n'
        'Python: https://www.python.org/\n'
        'PyInstaller (bootloader exception): https://pyinstaller.org/en/stable/license.html\n'
        'Network helper source is included in network/source. License texts are in network/licenses.\n',
        encoding='utf-8')


if __name__ == '__main__':
    main()
