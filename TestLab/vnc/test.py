#!/usr/bin/env python3
"""Exercise Linux file clipboard against the Docker TigerVNC/Xfce desktop.
Credentials and the SSH master are disposable. Never reads the user's clipboard.
"""
import argparse
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import time

REPO = Path(__file__).resolve().parents[2]


def run(*args):
    subprocess.run([str(a) for a in args], cwd=REPO, check=True, timeout=600)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--test', action='append')
    parser.add_argument('--via-bastion', action='store_true')
    args = parser.parse_args()
    suites = args.test or ['VNCLinuxFileValidationTests', 'VNCLinuxFilesTests']
    selection = [f'-only-testing:TermsteadTests/{test}' for test in suites]
    run('xcodegen', 'generate')
    run('xcodebuild', '-project', 'Termstead.xcodeproj', '-scheme', 'Termstead',
        '-derivedDataPath', 'build', *selection, 'build-for-testing')
    products = REPO / 'build/Build/Products'
    source = max(products.glob('Termstead_macosx*-arm64.xctestrun'), key=lambda p: p.stat().st_mtime)

    def relocate(value):
        if isinstance(value, str):
            return value.replace('__TESTROOT__', str(source.parent))
        if isinstance(value, list):
            return [relocate(item) for item in value]
        if isinstance(value, dict):
            return {key: relocate(item) for key, item in value.items()}
        return value

    with tempfile.TemporaryDirectory(prefix='ts-linux-', dir='/private/tmp') as directory:
        root = Path(directory)
        key = root / 'key'
        shutil.copyfile(Path.home() / '.ssh/termstead-lab', key)
        key.chmod(0o600)
        public = (REPO / 'TestLab/.state/hostkeys/vnc.pub').read_text().split()
        known = root / 'known_hosts'
        known.write_text(f'vnc,[127.0.0.1]:2203 {public[0]} {public[1]}\n')
        # OpenSSH allows comma-separated host aliases on a single key line.
        if args.via_bastion:
            public = (REPO / 'TestLab/.state/hostkeys/bastion.pub').read_text().split()
            with known.open('a') as output:
                output.write(f'[127.0.0.1]:2202 {public[0]} {public[1]}\n')
        config = root / 'config'
        control = root / 'cm'
        common = f' IdentityFile {key}\n UserKnownHostsFile {known}\n StrictHostKeyChecking yes\n IdentitiesOnly yes\n BatchMode yes\n User lab\n'
        target = (' HostName vnc\n Port 22\n ProxyJump linux-bastion\n' if args.via_bastion
                  else ' HostName 127.0.0.1\n Port 2203\n')
        config.write_text('Host linux-vnc-test\n' + target + common +
                          'Host linux-bastion\n HostName 127.0.0.1\n Port 2202\n' + common)
        config.chmod(0o600)
        spec = relocate(plistlib.loads(source.read_bytes()))
        target_spec = spec['TermsteadTests']
        environment = target_spec.setdefault('TestingEnvironmentVariables', {})
        embedded = target_spec['TestHostPath'] + '/Contents/Frameworks'
        environment['DYLD_FRAMEWORK_PATH'] = embedded + ':' + environment.get('DYLD_FRAMEWORK_PATH', '')
        target_spec.setdefault('EnvironmentVariables', {}).update({
            'TERMSTEAD_LINUX_SSH_CONFIG': str(config),
            'TERMSTEAD_LINUX_SSH_CONTROL': str(control),
        })
        target = root / 'tests.xctestrun'
        target.write_bytes(plistlib.dumps(spec))
        master = subprocess.Popen(['ssh', '-F', str(config), '-M', '-N', '-S', str(control),
                                   'linux-vnc-test'], stdin=subprocess.DEVNULL)
        try:
            deadline = time.monotonic() + 15
            while not control.exists() and master.poll() is None and time.monotonic() < deadline:
                time.sleep(.05)
            if not control.exists():
                raise RuntimeError('SSH lab did not connect. Run TestLab/lab.sh up first.')
            run('xcodebuild', 'test-without-building', '-xctestrun', target,
                '-destination', 'platform=macOS,arch=arm64', *selection)
        finally:
            master.terminate()
            try:
                master.wait(timeout=5)
            except subprocess.TimeoutExpired:
                master.kill()
                master.wait()


if __name__ == '__main__':
    main()
