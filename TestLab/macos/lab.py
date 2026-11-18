#!/usr/bin/env python3
"""Persistent, host-only macOS VNC lab. Never uses the user's ~/.tart or sessions.

  lab.py fetch   download/clone the pinned macOS image
  lab.py up      boot, provision SSH/Screen Sharing, publish localhost:15900
  lab.py open    open the Release build on its isolated macos-vnc-test profile
  lab.py status  show VM, tunnel and download status
  lab.py down    graceful shutdown; retain the VM and cache
"""
import argparse
import fcntl
import json
import os
import pathlib
import shlex
import subprocess
import time
import uuid

REPO = pathlib.Path(__file__).resolve().parents[2]
ROOT = REPO / 'TestLab/.state/macos'
STORAGE = ROOT / 'storage'
TART = ROOT / 'tool/tart.app/Contents/MacOS/tart'
VM = 'termstead-vnc-macos'
IMAGE = 'ghcr.io/cirruslabs/macos-tahoe-vanilla@sha256:eeec54bfe1f076e27786c5d92b89187a05b1d109b5071eb2dcdf02d596e34640'
ENV = dict(os.environ, TART_HOME=str(STORAGE), TART_NO_AUTO_PRUNE='1')
CONFIG = ROOT / 'ssh_config'


def run(args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, timeout=90, **kwargs)


def tart(*args, **kwargs):
    return run([TART, *args], env=ENV, **kwargs)


def exists():
    return (STORAGE / 'vms' / VM / 'config.json').exists()


def state():
    result = tart('list', '--format', 'json', capture_output=True, text=True)
    rows = json.loads(result.stdout)
    return next((row.get('State', row.get('state', 'unknown')) for row in rows
                 if row.get('Name', row.get('name')) == VM), 'missing')


def ssh(command, **kwargs):
    return run(['/usr/bin/ssh', '-F', CONFIG, 'macos-vnc-vm', command], **kwargs)


def fetch():
    if exists():
        return
    if not TART.exists():
        raise SystemExit('Tart is missing. Install the verified release in TestLab/.state/macos/tool first; see README.md.')
    from fetch import download, serve, DIGEST, REPOSITORY
    download()
    registry = serve()
    try:
        # Verified bytes are served only over loopback. Tart still validates
        # the OCI manifest and assembles the original native disk format.
        with (ROOT / 'clone.log').open('w') as log:
            subprocess.run([str(TART), 'clone', f'127.0.0.1:50442/{REPOSITORY}@{DIGEST}', VM,
                            '--insecure', '--concurrency', '4'], env=ENV,
                           stdout=log, stderr=subprocess.STDOUT, check=True)
    finally:
        registry.shutdown(); registry.server_close()



def detach(args, log, pidfile, env=None):
    with log.open('a') as output:
        p = subprocess.Popen([str(a) for a in args], env=env, stdin=subprocess.DEVNULL,
                             stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
    pidfile.write_text(str(p.pid))


def up():
    fetch()
    if state().lower() != 'running':
        tart('set', VM, '--cpu', '2', '--memory', '4096')
        detach([TART, 'run', VM, '--no-graphics', '--no-audio', '--no-clipboard', '--no-usb-accessories', '--net-host'],
               ROOT / 'vm.log', ROOT / 'vm.pid', ENV)
    result = tart('ip', VM, '--resolver', 'dhcp', '--wait', '60', capture_output=True, text=True)
    address = result.stdout.strip()
    if not address:
        raise SystemExit('No guest IP yet. Retry lab.py up after the guest has booted.')
    key = ROOT / 'id_ed25519'
    if not key.exists():
        run(['/usr/bin/ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-C', 'termstead-macos-lab', '-f', key])
    CONFIG.write_text(f'''Host macos-vnc-vm
    HostName {address}
    HostKeyAlias termstead-macos-lab
    User admin
    IdentityFile "{key}"
    IdentitiesOnly yes
    UserKnownHostsFile "{ROOT / 'known_hosts'}"
    StrictHostKeyChecking accept-new
    ConnectTimeout 5
    ServerAliveInterval 10
    ServerAliveCountMax 3
''')
    CONFIG.chmod(0o600)
    askpass = ROOT / 'askpass'
    askpass.write_text('#!/bin/sh\nprintf "%s\\n" admin\n'); askpass.chmod(0o700)
    bootstrap_env = dict(os.environ, SSH_ASKPASS=str(askpass), SSH_ASKPASS_REQUIRE='force', DISPLAY=':0')
    public = (ROOT / 'id_ed25519.pub').read_text().strip()
    install_key = ('mkdir -p ~/.ssh; chmod 700 ~/.ssh; touch ~/.ssh/authorized_keys; '
                   f'grep -qxF {shlex.quote(public)} ~/.ssh/authorized_keys || '
                   f'printf "%s\\n" {shlex.quote(public)} >> ~/.ssh/authorized_keys; chmod 600 ~/.ssh/authorized_keys')
    for _ in range(45):
        try:
            ssh(install_key, env=bootstrap_env, stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
            break
        except subprocess.CalledProcessError:
            time.sleep(2)
    else:
        raise SystemExit('SSH login failed. See vm.log; the guest test account is admin/admin.')
    # Changes apply only inside the isolated test VM.
    ssh('sudo -n launchctl enable system/com.apple.screensharing; '
        'sudo -n launchctl bootstrap system /System/Library/LaunchDaemons/com.apple.screensharing.plist 2>/dev/null || true; '
        'sudo -n launchctl kickstart system/com.apple.screensharing')
    tunnel = ['/usr/bin/ssh', '-F', CONFIG, '-N', '-o', 'ExitOnForwardFailure=yes',
              '-L', '127.0.0.1:15900:127.0.0.1:5900', 'macos-vnc-vm']
    if not listening():
        detach(tunnel, ROOT / 'tunnel.log', ROOT / 'tunnel.pid')
        for _ in range(30):
            if listening(): break
            time.sleep(0.2)
        else: raise SystemExit('Tunnel did not start; see tunnel.log.')
    profile()
    print('macOS VNC lab ready: 127.0.0.1:15900, admin/admin. Run lab.py open.')


def listening():
    import socket
    try:
        with socket.create_connection(('127.0.0.1', 15900), timeout=1): return True
    except OSError:
        return False


def profile():
    path = ROOT / 'sessions.json'
    address = next(line.split(None, 1)[1] for line in CONFIG.read_text().splitlines()
                   if line.strip().startswith('HostName '))
    access = {'host': address, 'port': 22, 'user': 'admin', 'auth': 'key',
              'keyPath': str(ROOT / 'id_ed25519')}
    if path.exists():
        snapshot = json.loads(path.read_text())
        for saved in snapshot.get('sessions', []):
            if saved.get('id') == 'macos-vnc-test':
                saved.setdefault('vncOptions', {})['fileAccess'] = access
                path.write_text(json.dumps(snapshot, indent=2)); path.chmod(0o600)
                return
    session = {'id': 'macos-vnc-test', 'persistentID': str(uuid.uuid4()), 'user': 'admin',
               'host': '127.0.0.1', 'port': 15900, 'icon': 'monitor', 'auth': 'password',
               'keyPath': '', 'jumps': [], 'sessionKind': 'vnc',
               'vncOptions': {'keyboard': 'macOS', 'clipboard': True, 'sendClipboard': True,
                              'receiveClipboard': True, 'autoReconnect': False,
                              'fileAccess': access}}
    snapshot = {'version': 2, 'sessions': [session], 'tree': [
        {'id': 'macos-lab', 'name': 'macOS VNC lab', 'children': [{'session': {'_0': session['id']}}]}],
        'pinnedIDs': [], 'collapsedGroupIDs': []}
    path.write_text(json.dumps(snapshot, indent=2)); path.chmod(0o600)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('action', choices=['fetch', 'up', 'open', 'status', 'down'])
    parser.add_argument("--open", dest="open_when_ready", action="store_true", help="open Termstead once up completes")
    args = parser.parse_args()
    action = args.action
    ROOT.mkdir(parents=True, exist_ok=True); ROOT.chmod(0o700)
    operation = None
    if action in ('fetch', 'up'):
        operation = (ROOT / 'operation.lock').open('w')
        try: fcntl.flock(operation, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError: raise SystemExit('The macOS lab is already being prepared; run lab.py status.')
        (ROOT / 'setup.pid').write_text(str(os.getpid()))
    if action == 'fetch': fetch()
    elif action == 'up':
        up()
        if args.open_when_ready:
            run(['/usr/bin/open', '-n', REPO / 'build/Build/Products/Release/Termstead.app', '--args',
                 '-sb-store', ROOT / 'sessions.json', '-sb-connect', 'macos-vnc-test', '-files.showAfterLogin', 'NO'])
    elif action == 'open':
        if not listening(): raise SystemExit('The macOS VNC lab is not running. Run lab.py up first.')
        profile()
        app = REPO / 'build/Build/Products/Release/Termstead.app'
        run(['/usr/bin/open', '-n', app, '--args', '-sb-store', ROOT / 'sessions.json',
             '-sb-connect', 'macos-vnc-test', '-files.showAfterLogin', 'NO'])
    elif action == 'status':
        print('Storage:', STORAGE)
        print('VM:', state() if TART.exists() else 'Tart missing')
        print('VNC tunnel:', 'listening on 127.0.0.1:15900' if listening() else 'stopped')
        if (ROOT / 'download-status.json').exists():
            d = json.loads((ROOT / 'download-status.json').read_text())
            print('Download:', f"{d['downloaded']/1e9:.2f} / {d['total']/1e9:.2f} GB", 'verified' if d.get('complete') else 'in progress')
        elif (ROOT / 'clone.log').exists(): print('Download:', (ROOT / 'clone.log').read_text()[-400:].strip())
    elif action == 'down':
        if state().lower() == 'running':
            result = subprocess.run(['/usr/bin/ssh', '-F', str(CONFIG), 'macos-vnc-vm', 'sudo -n shutdown -h now'], timeout=30)
            if result.returncode not in (0, 255): raise SystemExit(result.returncode)
            for _ in range(30):
                if state().lower() != 'running': break
                time.sleep(1)
        print('VM:', state(), '(disk and cache retained)')


if __name__ == '__main__': main()
