#!/usr/bin/env python3
"""Ephemeral X11 file clipboard bridge. JSON control travels over the user's SSH
connection; file contents travel over SFTP. Nothing listens on a network port.
Requires Python 3, PyGObject and GTK 3 in the logged-in desktop user's account.
"""
import json
import os
from pathlib import Path
import shutil
import stat
import sys
import tempfile
import time
from urllib.parse import urlsplit, unquote

LIMIT = 100 * 1024**3
MAX_ITEMS = 10000
MAX_LINE = 128 * 1024
MARKER = '.termstead-clipboard-cache.json'


def prune_cache(home, now):
    """Only old, private directories created by this bridge are disposable."""
    for folder in home.glob('.termstead-vnc-*'):
        try:
            info = folder.lstat()
            marker = folder / MARKER
            stamp = marker.lstat()
            if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
                continue
            if not stat.S_ISREG(stamp.st_mode) or stamp.st_uid != os.getuid() or stamp.st_size > 1024:
                continue
            value = json.loads(marker.read_text())
            created = value.get('created')
            if value.get('version') == 1 and isinstance(created, (int, float)) and 0 < created < now - 7 * 86400:
                shutil.rmtree(folder)
        except (OSError, ValueError, TypeError, AttributeError):
            pass


def emit(**value):
    print(json.dumps(value, ensure_ascii=True, separators=(',', ':')), flush=True)


def inventory(paths):
    total, count = 0, 0
    roots = []
    for path in paths:
        if not path.startswith('/') or any(c in path for c in '\0\r\n') or len(os.fsencode(path)) > 4096:
            raise ValueError('File paths must be absolute and cannot contain newlines.')
        pending = [path]
        while pending:
            current = pending.pop()
            info = os.lstat(current)
            count += 1
            if count > MAX_ITEMS:
                raise ValueError('A copy can contain at most 10,000 items.')
            if stat.S_ISDIR(info.st_mode):
                with os.scandir(current) as entries:
                    for entry in entries:
                        if any(c in entry.name for c in '\r\n'):
                            raise ValueError('SFTP clipboard copies cannot contain names with newlines.')
                        pending.append(entry.path)
                        if len(pending) + count > MAX_ITEMS:
                            raise ValueError('A copy can contain at most 10,000 items.')
            elif stat.S_ISREG(info.st_mode):
                total += info.st_size
                if total > LIMIT:
                    raise ValueError('A copy can contain at most 100 GB.')
            else:
                raise ValueError('Symbolic links and special files cannot be copied through the clipboard.')
        roots.append({'path': path, 'directory': os.path.isdir(path)})
    return roots, total


def file_paths(data):
    if len(data) > MAX_LINE:
        raise ValueError('The file clipboard is too large.')
    paths = []
    for line in data.decode('utf-8', errors='strict').splitlines():
        if not line or line.startswith('#') or line in ('copy', 'cut'):
            continue
        url = urlsplit(line)
        if url.scheme != 'file' or url.netloc not in ('', 'localhost') or url.query or url.fragment:
            raise ValueError('Only files on this Linux desktop can be copied.')
        path = unquote(url.path, errors='strict')
        if path not in paths:
            paths.append(path)
        if len(paths) > 64:
            raise ValueError('Select at most 64 files or folders at a time.')
    return paths


def file_selection(data):
    """An automatic clipboard inspection may encounter an expired selection.
    Keep the selection atomic and never turn missing file URLs into text.
    Actual upload/download failures still report their errors normally.
    """
    try:
        roots, total = inventory(file_paths(data))
        return {'files': roots, 'total': total, 'stale': False}
    except FileNotFoundError:
        return {'files': [], 'total': 0, 'stale': True}


def main():
    # Never guess between several desktops. SSH sessions commonly have no
    # DISPLAY; selecting the sole local X server is safe, ambiguity is an error.
    if not os.environ.get('DISPLAY'):
        displays = sorted(Path('/tmp/.X11-unix').glob('X[0-9]*'))
        if len(displays) != 1:
            raise RuntimeError('Set DISPLAY in the SSH account to the VNC desktop (for example :1).')
        os.environ['DISPLAY'] = ':' + displays[0].name[1:]
    try:
        import gi
        gi.require_version('Gtk', '3.0')
        gi.require_version('Gdk', '3.0')
        from gi.repository import Gdk, GLib, Gtk
    except (ImportError, ValueError) as error:
        raise RuntimeError('Linux file clipboard requires python3-gi and gir1.2-gtk-3.0 (GTK 3).') from error
    if not Gtk.init_check([])[0]:
        raise RuntimeError('Cannot open the VNC X11 desktop. Use SSH as its logged-in user and check DISPLAY/XAUTHORITY.')
    if Gdk.Display.get_default().get_name().startswith('wayland'):
        raise RuntimeError('This file clipboard bridge currently supports X11 desktops only.')

    clipboard = Gtk.Clipboard.get(Gdk.SELECTION_CLIPBOARD)
    widget = Gtk.Invisible()
    widget.realize()
    targets = ['text/uri-list', 'x-special/gnome-copied-files', 'application/x-kde-cutselection']
    Gtk.selection_add_targets(widget, Gdk.SELECTION_CLIPBOARD,
                              [Gtk.TargetEntry.new(name, 0, index) for index, name in enumerate(targets)])
    state = {'active': False, 'serial': 0, 'uris': [], 'owned': False}
    stages = {}
    prune_cache(Path.home(), time.time())
    publication = {'serial': 0, 'pending': None}

    def publication_ready(serial):
        pending = publication['pending']
        if pending is None or pending[0] != serial:
            return False
        publication['pending'] = None
        # GTK has replied to TARGETS before this idle callback. Flush that
        # reply before acknowledging publication over SSH, so a file manager
        # updates its Paste sensitivity before the viewer's right click.
        Gdk.Display.get_default().flush()
        if Gdk.selection_owner_get(Gdk.SELECTION_CLIPBOARD) == widget.get_window():
            emit(**pending[1])
        else:
            emit(id=pending[1]['id'], error='The Linux clipboard changed before the files were ready.')
        return False

    def selection_requested(_widget, event):
        pending = publication['pending']
        if pending is not None and event.target == Gdk.Atom.intern('TARGETS', False):
            GLib.idle_add(publication_ready, pending[0])
        return False  # let GTK send the normal selection response

    widget.connect('selection-request-event', selection_requested)

    def get_selection(_widget, selection, info, _timestamp):
        uris = state['uris']
        value = ('\r\n'.join(uris) + '\r\n').encode() if info == 0 else (
            ('copy\n' + '\n'.join(uris)).encode() if info == 1 else b'0')
        selection.set(Gdk.Atom.intern(targets[info], False), 8, value)

    widget.connect('selection-get', get_selection)

    def inspect():
        if not state['active'] or state['owned']:
            return False
        serial = state['serial']

        def received(_clipboard, selection, _data):
            if serial != state['serial'] or not state['active'] or state['owned']:
                return
            try:
                # Some X11 owners (notably xclip) answer unsupported requests
                # with UTF8_STRING anyway. A string that resembles a file URL
                # must never authorize reading that file.
                data = (selection.get_data() or b'') if selection.get_data_type() == Gdk.Atom.intern('text/uri-list', False) else b''
                metadata = file_selection(data)
                emit(event='files', serial=serial, **metadata)
                if not metadata['files'] and not metadata['stale']:
                    def text_received(_clipboard, text, _data):
                        if serial == state['serial'] and state['active'] and not state['owned'] and text is not None:
                            if len(text.encode('utf-8')) <= 1024 * 1024:
                                emit(event='text', text=text)
                    clipboard.request_text(text_received, None)
            except (ValueError, OSError) as error:
                emit(event='copy-error', message=str(error))

        clipboard.request_contents(Gdk.Atom.intern('text/uri-list', False), received, None)
        return False

    def changed(_clipboard, _event):
        state['serial'] += 1
        state['owned'] = Gdk.selection_owner_get(Gdk.SELECTION_CLIPBOARD) == widget.get_window()
        if not state['owned']:
            emit(event='changed')  # metadata only, even in send-only mode
            GLib.idle_add(inspect)

    clipboard.connect('owner-change', changed)

    def handle(message):
        request = message.get('id')
        try:
            operation = message.get('operation')
            result = {}
            if operation == 'active':
                state['active'] = bool(message.get('active'))
                state['serial'] += 1
                GLib.idle_add(inspect)
            elif operation == 'stage':
                count = message.get('count', 0)
                token = message.get('token', '')
                if not isinstance(count, int) or not 1 <= count <= 64 or len(stages) >= 8:
                    raise ValueError('Too many pending clipboard files.')
                if not isinstance(token, str) or len(token) != 32 or any(c not in '0123456789abcdef' for c in token) or token in stages:
                    raise ValueError('Invalid upload request.')
                # A private directory directly below the user's home avoids
                # following a pre-existing, attacker-controlled cache symlink.
                directory = tempfile.mkdtemp(prefix='.termstead-vnc-', dir=Path.home())
                Path(directory, MARKER).write_text(json.dumps({'version': 1, 'created': time.time()}))
                for index in range(count):
                    os.mkdir(os.path.join(directory, str(index)), 0o700)
                stages[token] = (directory, count)
                result = {'token': token, 'path': directory}
            elif operation == 'publish':
                token = message.get('token')
                if token not in stages:
                    raise ValueError('The upload is no longer available.')
                directory, count = stages[token]
                paths = []
                for index in range(count):
                    entries = list(Path(directory, str(index)).iterdir())
                    if len(entries) != 1:
                        raise ValueError('The upload did not finish.')
                    paths.append(str(entries[0]))
                inventory(paths)
                state['uris'] = [Path(path).as_uri() for path in paths]
                state['owned'] = True
                if not Gtk.selection_owner_set(widget, Gdk.SELECTION_CLIPBOARD, Gdk.CURRENT_TIME):
                    state['owned'] = False
                    raise RuntimeError('The Linux desktop refused the file clipboard.')
                stages.pop(token)
                # Completed uploads outlive the SSH bridge so the desktop's
                # clipboard manager can still paste them. No arbitrary paths
                # supplied by the client are ever removed.
                result = {'files': paths}
                if publication['pending'] is not None:
                    publication_ready(publication['pending'][0])
                publication['serial'] += 1
                serial = publication['serial']
                publication['pending'] = (serial, {'id': request, **result})
                # Some desktops do not watch TARGETS until opening their menu.
                # Bound the acknowledgement wait without permanent polling.
                GLib.timeout_add(1000, publication_ready, serial)
                return
            elif operation == 'discard':
                stage = stages.pop(message.get('token'), None)
                if stage:
                    shutil.rmtree(stage[0])
            else:
                raise ValueError('Unknown clipboard operation.')
            emit(id=request, **result)
        except (ValueError, RuntimeError, OSError) as error:
            emit(id=request, error=str(error))

    buffer = bytearray()

    def read_input(_source, condition):
        chunk = os.read(sys.stdin.fileno(), 16384)
        if not chunk:
            Gtk.main_quit()
            return False
        buffer.extend(chunk)
        if len(buffer) > MAX_LINE:
            Gtk.main_quit()
            return False
        while b'\n' in buffer:
            line, _, rest = buffer.partition(b'\n')
            buffer[:] = rest
            try:
                message = json.loads(line)
                if not isinstance(message, dict):
                    raise ValueError('Expected a clipboard request.')
                handle(message)
            except (ValueError, TypeError) as error:
                emit(error=str(error))
        return True

    GLib.io_add_watch(sys.stdin.fileno(), GLib.IO_IN | GLib.IO_HUP, read_input)
    emit(event='ready', display=Gdk.Display.get_default().get_name())
    try:
        Gtk.main()
    finally:
        for directory, _count in stages.values():
            shutil.rmtree(directory, ignore_errors=True)


if __name__ == '__main__':
    try:
        main()
    except Exception as failure:
        emit(event='error', message=str(failure))
        sys.exit(1)
