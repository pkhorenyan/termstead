"""Remove only expired URI selections left by the disposable Linux test suite.
Never clears text, valid files, or selections outside its exact fixture roots.
"""
import os
import re
import subprocess
from urllib.parse import unquote, urlsplit

FIXTURE = re.compile(r'^(/tmp/termstead-linux-[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})/.+$')


def expired_fixture_selection(data, exists=os.path.lexists):
    try:
        urls = [line for line in data.decode('utf-8').splitlines() if line and not line.startswith('#')]
        if not urls:
            return False
        for value in urls:
            url = urlsplit(value)
            path = unquote(url.path, errors='strict')
            fixture = FIXTURE.fullmatch(path)
            if (url.scheme != 'file' or url.netloc not in ('', 'localhost') or url.query or url.fragment
                    or not fixture or '\0' in path or any(part in ('.', '..') for part in path.split('/'))
                    or exists(fixture[1]) or exists(path)):
                return False
        return True
    except (UnicodeError, ValueError, OSError):
        return False


def main():
    env = dict(os.environ, DISPLAY=':1')
    def read(target):
        result = subprocess.run(['timeout', '2', 'xclip', '-selection', 'clipboard', '-t', target, '-o'],
                                env=env, capture_output=True, timeout=3)
        return result.stdout if result.returncode == 0 else b''
    if b'text/uri-list' in read('TARGETS').splitlines() and expired_fixture_selection(read('text/uri-list')):
        subprocess.run(['xclip', '-selection', 'clipboard'], input=b'', env=env,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=3, check=True)
        print('Cleared expired Linux test-file clipboard.')


if __name__ == '__main__':
    main()
