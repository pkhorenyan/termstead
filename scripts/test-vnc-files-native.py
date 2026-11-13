#!/usr/bin/env python3
"""Interop oracle: stream files through the actual macOS file-copy helpers.

Works without Screen Sharing enabled or a VM. Uses re-signed temporary copies
of the helpers (the OS rejects their platform signatures outside their parent
service), as an ordinary user. No private helpers are shipped or used by the app.
"""
import hashlib
import pathlib
import shutil
import struct
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
SUPPORT = pathlib.Path('/System/Library/CoreServices/RemoteManagement/screensharingd.bundle/Contents/Support')


def run(args, **kwargs):
    return subprocess.run(args, check=True, timeout=90, **kwargs)


def digest(path):
    return hashlib.sha256(path.read_bytes()).digest()


with tempfile.TemporaryDirectory(prefix='termstead-native-files-') as temporary:
    root = pathlib.Path(temporary)
    for name in ['SSFileCopySender', 'SSFileCopyReceiver']:
        source = SUPPORT / (name + '.bundle') / 'Contents/MacOS' / name
        shutil.copyfile(source, root / name)
        (root / name).chmod(0o700)
        run(['/usr/bin/codesign', '--force', '--sign', '-', str(root / name)], capture_output=True)
    oracle = root / 'oracle'
    run(['/usr/bin/xcrun', 'swiftc', '-parse-as-library', '-swift-version', '6',
         str(ROOT / 'SharedVNC/VNCFileWire.swift'), str(ROOT / 'SharedVNC/VNCFileStream.swift'),
         str(ROOT / 'TestLab/vnc/native-files.swift'), '-o', str(oracle)])
    source = root / 'Папка 🙂'
    source.mkdir(); (source / 'nested').mkdir()
    (source / 'empty').write_bytes(b'')
    (source / 'nested/данные.txt').write_text('Termstead — привет 日本語 🙂\n')
    (source / 'binary').write_bytes(bytes(range(256)) * 4097)
    resource = source / 'nested/данные.txt/..namedfork/rsrc'
    with open(resource, 'wb') as stream:
        stream.write(b'Termstead resource fork' * 4000)
    path = str(source).encode()
    native = run([str(root / 'SSFileCopySender')], input=struct.pack('<HIH', 1, 123, len(path)) + path,
                 capture_output=True).stdout
    (root / 'native.bin').write_bytes(native)
    run([str(oracle), 'receive', str(root / 'native.bin'), str(root / 'received')])
    received = root / 'received' / source.name
    for name in ['empty', 'binary', 'nested/данные.txt', 'nested/данные.txt/..namedfork/rsrc']:
        assert digest(source / name) == digest(received / name), ('native → Termstead', name)
    assert abs((source / 'binary').stat().st_mtime - (received / 'binary').stat().st_mtime) < 1
    run([str(oracle), 'send', str(source), str(root / 'outgoing.bin')])
    wire = (root / 'outgoing.bin').read_bytes()
    destination = root / 'remote'; destination.mkdir()
    offset = 0
    messages = []
    while offset < len(wire):
        length = struct.unpack_from('>I', wire, offset + 2)[0]
        packet = bytearray(wire[offset:offset + 6 + length]); offset += 6 + length
        version, kind, sid = struct.unpack_from('>HHI', packet, 6)
        if kind == 2:
            path = str(destination).encode()
            packet = bytearray(b'\x22\x02' + struct.pack('>IHHIIIH', 18 + len(path), 1, 2, sid, 0, 4, len(path)) + path)
            length = len(packet) - 6
            struct.pack_into('<I', packet, 14, 0)
            struct.pack_into('<H', packet, 22, len(path))
        # screensharingd forwards these header fields in host byte order.
        struct.pack_into('<HIHHI', packet, 0, 2, length, version, kind, sid)
        messages.append(packet)
    result = run([str(root / 'SSFileCopyReceiver')], input=b''.join(messages), capture_output=True).stdout
    assert len(result) >= 6 and result[:4] == b'\1\0\0\0', 'native receiver reported an error'
    remote = next(destination.iterdir()) / source.name
    for name in ['empty', 'binary', 'nested/данные.txt', 'nested/данные.txt/..namedfork/rsrc']:
        assert digest(source / name) == digest(remote / name), ('Termstead → native', name)
    assert abs((source / 'binary').stat().st_mtime - (remote / 'binary').stat().st_mtime) < 1
    print('PASS: native macOS file-copy helpers in both directions; binary, Unicode, nested folders, empty files and resource forks')
