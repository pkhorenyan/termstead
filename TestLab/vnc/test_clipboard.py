"""Bounds and cleanup checks for the same bridge shipped in the app."""
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest

source = Path(__file__).resolve().parents[2] / 'Resources/VNC/linux-clipboard.py'
spec = importlib.util.spec_from_file_location('clipboard', source)
clipboard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(clipboard)
cleanup_spec = importlib.util.spec_from_file_location('cleanup', source.parents[2] / 'TestLab/vnc/cleanup-clipboard.py')
cleanup = importlib.util.module_from_spec(cleanup_spec)
cleanup_spec.loader.exec_module(cleanup)


class ClipboardTests(unittest.TestCase):
    def test_missing_file_selection_is_stale_and_recovers_on_the_next_copy(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            live = root / 'live.txt'
            live.write_bytes(b'123')
            data = (live.as_uri() + '\r\n' + (root / 'missing.txt').as_uri()).encode()
            self.assertEqual(clipboard.file_selection(data), {'files': [], 'total': 0, 'stale': True})
            valid = clipboard.file_selection(live.as_uri().encode())
            self.assertFalse(valid['stale'])
            self.assertEqual(valid['total'], 3)
            self.assertEqual(valid['files'], [{'path': str(live), 'directory': False}])

    def test_cleanup_is_limited_to_missing_test_fixture_selections(self):
        path = '/tmp/termstead-linux-12345678-1234-1234-1234-123456789ABC/menu-proof.txt'
        data = ('file://' + path).encode()
        self.assertTrue(cleanup.expired_fixture_selection(data, exists=lambda _: False))
        self.assertFalse(cleanup.expired_fixture_selection(data, exists=lambda p: p == path))
        self.assertFalse(cleanup.expired_fixture_selection(data, exists=lambda p: p == path.rsplit('/', 1)[0]))
        for value in [b'', b'plain text', b'file:///home/lab/Desktop/user.txt', data + b'\nfile:///home/lab/user.txt',
                      b'file://other' + path.encode(), data + b'?query']:
            self.assertFalse(cleanup.expired_fixture_selection(value, exists=lambda _: False))

    def test_uri_names_and_rejected_network_paths(self):
        self.assertEqual(clipboard.file_paths('file:///tmp/test_rdp\r\nfile:///tmp/%D0%A4%D0%B0%D0%B9%D0%BB%20%25.txt\r\n'.encode()),
                         ['/tmp/test_rdp', '/tmp/Файл %.txt'])
        for value in ['sftp://host/etc/passwd', 'file://other/etc/passwd', 'file:///tmp/a?query']:
            with self.assertRaises(ValueError):
                clipboard.file_paths(value.encode())

    def test_links_and_newlines_cannot_escape_an_inventory(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'empty').mkdir()
            (root / 'file').write_bytes(b'123')
            roots, size = clipboard.inventory([str(root)])
            self.assertEqual(size, 3)
            self.assertTrue(roots[0]['directory'])
            (root / 'link').symlink_to('/etc')
            with self.assertRaises(ValueError):
                clipboard.inventory([str(root)])
            (root / 'link').unlink()
            (root / 'unsafe\nname').touch()
            with self.assertRaises(ValueError):
                clipboard.inventory([str(root)])

    def test_cache_cleanup_requires_an_old_private_owned_marker(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            def stage(name, created, marker=True):
                folder = home / name
                folder.mkdir(mode=0o700)
                if marker:
                    (folder / clipboard.MARKER).write_text(json.dumps({'version': 1, 'created': created}))
                return folder
            old = stage('.termstead-vnc-old', 1)
            recent = stage('.termstead-vnc-recent', 999999)
            unrelated = stage('.termstead-vnc-unrelated', 1, marker=False)
            public = stage('.termstead-vnc-public', 1)
            public.chmod(0o755)
            link = home / '.termstead-vnc-link'
            link.symlink_to(recent, target_is_directory=True)
            clipboard.prune_cache(home, 1000000)
            self.assertFalse(old.exists())
            self.assertTrue(recent.exists())
            self.assertTrue(unrelated.exists())
            self.assertTrue(public.exists())
            self.assertTrue(link.is_symlink())


if __name__ == '__main__':
    unittest.main()
