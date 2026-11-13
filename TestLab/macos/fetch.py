#!/usr/bin/env python3
"""Fetch the pinned public VM in resumable ranges; verify every OCI digest.

Only a loopback HTTP registry serves the verified local files to Tart. No
credentials or arbitrary remote URLs are accepted by that server.
"""
import concurrent.futures
import hashlib
import http.server
import json
import os
import pathlib
import threading
import time
import urllib.error
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1] / '.state/macos'
DIGEST = 'sha256:eeec54bfe1f076e27786c5d92b89187a05b1d109b5071eb2dcdf02d596e34640'
REPOSITORY = 'cirruslabs/macos-tahoe-vanilla'
CACHE = ROOT / 'blob-cache'
CHUNK = 8 << 20
LOCK = threading.Lock()
TOKEN = ''
TOKEN_AT = 0


def auth():
    global TOKEN, TOKEN_AT
    with LOCK:
        if time.monotonic() - TOKEN_AT > 120 or not TOKEN:
            url = f'https://ghcr.io/token?service=ghcr.io&scope=repository:{REPOSITORY}:pull'
            with urllib.request.urlopen(url, timeout=30) as response:
                TOKEN = json.load(response)['token']; TOKEN_AT = time.monotonic()
        return TOKEN


def request(url, extra=None):
    return urllib.request.Request(url, headers={'Authorization': 'Bearer ' + auth(), **(extra or {})})


def checksum(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        while chunk := stream.read(4 << 20): h.update(chunk)
    return 'sha256:' + h.hexdigest()


def download():
    ROOT.mkdir(parents=True, exist_ok=True); CACHE.mkdir(exist_ok=True)
    manifest_file = ROOT / 'image-manifest.json'
    if not manifest_file.exists():
        url = f'https://ghcr.io/v2/{REPOSITORY}/manifests/{DIGEST}'
        with urllib.request.urlopen(request(url, {'Accept': 'application/vnd.oci.image.manifest.v1+json'}), timeout=30) as r:
            raw = r.read()
        assert 'sha256:' + hashlib.sha256(raw).hexdigest() == DIGEST, 'manifest digest mismatch'
        manifest_file.write_bytes(raw)
    assert checksum(manifest_file) == DIGEST
    manifest = json.loads(manifest_file.read_bytes())
    blobs = {x['digest']: x for x in [manifest['config'], *manifest['layers']]}
    jobs = []
    total = sum(x['size'] for x in blobs.values())
    progress = {'downloaded': 0, 'total': total, 'complete': False}
    progress_lock = threading.Lock()
    handles = {}
    masks = {}
    for digest, blob in blobs.items():
        path = CACHE / digest.split(':')[1]
        if path.exists() and path.stat().st_size == blob['size'] and checksum(path) == digest:
            progress['downloaded'] += blob['size']; continue
        fd = os.open(str(path) + '.partial', os.O_CREAT | os.O_RDWR, 0o600)
        os.ftruncate(fd, blob['size']); handles[digest] = fd
        mask_path = pathlib.Path(str(path) + '.ranges.json')
        done = set(json.loads(mask_path.read_text())) if mask_path.exists() else set()
        masks[digest] = done
        for offset in range(0, blob['size'], CHUNK):
            count = min(CHUNK, blob['size'] - offset)
            if offset in done: progress['downloaded'] += count
            else: jobs.append((digest, blob['size'], offset, count))
    started = time.monotonic(); initial = progress['downloaded']
    stop = threading.Event()
    def report():
        while not stop.wait(10):
            with progress_lock:
                status = dict(progress)
            status['MB_per_second'] = round((status['downloaded'] - initial) / (time.monotonic() - started) / 1e6, 2)
            (ROOT / 'download-status.json').write_text(json.dumps(status))
            print(f"{status['downloaded']/1e9:.2f} / {total/1e9:.2f} GB ({100*status['downloaded']/total:.1f}%), {status['MB_per_second']} MB/s", flush=True)
    reporter = threading.Thread(target=report, daemon=True); reporter.start()
    def part(job):
        digest, size, offset, count = job
        for attempt in range(7):
            try:
                url = f'https://ghcr.io/v2/{REPOSITORY}/blobs/{digest}'
                header = {'Range': f'bytes={offset}-{offset+count-1}'}
                with urllib.request.urlopen(request(url, header), timeout=45) as response:
                    expected = f'bytes {offset}-{offset+count-1}/{size}'
                    assert (response.status == 206 and response.headers.get('Content-Range') == expected) or (response.status == 200 and offset == 0 and count == size)
                    written = 0
                    while written < count:
                        data = response.read(min(1 << 20, count - written))
                        if not data: raise OSError('incomplete range')
                        n = os.pwrite(handles[digest], data, offset + written)
                        if n != len(data): raise OSError('short disk write')
                        written += n
                with progress_lock:
                    masks[digest].add(offset); progress['downloaded'] += count
                    path = CACHE / (digest.split(':')[1] + '.ranges.json')
                    temporary = pathlib.Path(str(path) + '.tmp')
                    temporary.write_text(json.dumps(sorted(masks[digest])))
                    temporary.replace(path)
                return
            except Exception:
                if attempt == 6: raise
                time.sleep(min(1 << attempt, 15))
    try:
        with concurrent.futures.ThreadPoolExecutor(max_workers=64) as pool:
            for _ in pool.map(part, jobs): pass
        for digest, fd in handles.items():
            os.fsync(fd); os.close(fd)
            path = CACHE / digest.split(':')[1]
            partial = pathlib.Path(str(path) + '.partial')
            if checksum(partial) != digest:
                pathlib.Path(str(path) + '.ranges.json').unlink(missing_ok=True)
                raise RuntimeError('blob digest mismatch; rerun to download it again')
            partial.rename(path)
        progress['complete'] = True
        (ROOT / 'download-status.json').write_text(json.dumps(progress))
        print('All VM blobs downloaded and SHA-256 verified.', flush=True)
    finally:
        stop.set(); reporter.join()
    return manifest


def serve():
    manifest = json.loads((ROOT / 'image-manifest.json').read_bytes())
    blobs = {x['digest']: x for x in [manifest['config'], *manifest['layers']]}
    class Registry(http.server.BaseHTTPRequestHandler):
        def log_message(self, *args): pass
        def do_HEAD(self):
            self.head_only = True
            self.do_GET()
        def do_GET(self):
            if self.path.rstrip('/') == '/v2':
                data = b'{}'; content_type = 'application/json'; digest = None
            elif self.path in [f'/v2/{REPOSITORY}/manifests/latest', f'/v2/{REPOSITORY}/manifests/{DIGEST}']:
                data = (ROOT / 'image-manifest.json').read_bytes()
                content_type = 'application/vnd.oci.image.manifest.v1+json'; digest = DIGEST
            elif self.path.startswith(f'/v2/{REPOSITORY}/blobs/'):
                digest = self.path.rsplit('/', 1)[1]
                if digest not in blobs: self.send_error(404); return
                path = CACHE / digest.split(':')[1]
                if not path.exists(): self.send_error(503); return
                self.send_response(200); self.send_header('Content-Length', str(path.stat().st_size))
                self.send_header('Content-Type', 'application/octet-stream'); self.end_headers()
                if getattr(self, 'head_only', False): return
                with path.open('rb') as stream:
                    while chunk := stream.read(1 << 20): self.wfile.write(chunk)
                return
            else: self.send_error(404); return
            self.send_response(200); self.send_header('Content-Type', content_type)
            self.send_header('Content-Length', str(len(data)))
            if digest: self.send_header('Docker-Content-Digest', digest)
            self.end_headers()
            if not getattr(self, 'head_only', False): self.wfile.write(data)
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 50442), Registry)
    thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
    return server


if __name__ == '__main__': download()
