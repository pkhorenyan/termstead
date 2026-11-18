#!/usr/bin/env python3
"""Run native VNC interop tests with the persistent, isolated macOS lab."""
import pathlib
import plistlib
import subprocess

from lab import REPO, ROOT, CONFIG


def run(args):
    subprocess.run([str(a) for a in args], cwd=REPO, check=True, timeout=600)


if __name__ == '__main__':
    if not CONFIG.exists():
        raise SystemExit('Start the isolated VM with TestLab/macos/lab.py up first.')
    suites = ['VNCMacOSTests', 'VNCAppleClipboardTests']
    selection = [f'-only-testing:TermsteadTests/{suite}' for suite in suites]
    run(['xcodebuild', '-project', 'Termstead.xcodeproj', '-scheme', 'Termstead',
         '-derivedDataPath', 'build', *selection, 'build-for-testing'])
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

    spec = relocate(plistlib.loads(source.read_bytes()))
    spec['TermsteadTests'].setdefault('EnvironmentVariables', {}).update({
        'TERMSTEAD_MACOS_VNC_HOST': '127.0.0.1',
        'TERMSTEAD_MACOS_VNC_PORT': '15900',
        'TERMSTEAD_MACOS_VNC_SSH_CONFIG': str(CONFIG),
    })
    target = ROOT / 'integration.xctestrun'
    target.write_bytes(plistlib.dumps(spec))
    run(['xcodebuild', 'test-without-building', '-xctestrun', target,
         '-destination', 'platform=macOS,arch=arm64', *selection])
