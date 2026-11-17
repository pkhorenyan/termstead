# Linux VNC file clipboard

Termstead can copy files and folders between Finder and an **X11 Linux VNC
desktop** using SSH/SFTP alongside VNC. Tested with TigerVNC and Xfce/Thunar.
VNC itself continues to carry the screen, keyboard and pointer.

1. Enable SSH/SFTP on the Linux machine. Log in as the user running the VNC desktop.
2. Install Python 3, PyGObject and GTK 3 on Linux. On Debian/Ubuntu:
   `sudo apt install python3 python3-gi gir1.2-gtk-3.0`.
3. Open an SSH tab to that machine in Termstead, then open its VNC session
   with the Linux keyboard profile and clipboard sharing enabled.
4. Right-click the VNC tab → **Linux File Clipboard** → choose that SSH tab.
   Choose the connection to the same desktop/user, including its jump hosts.
5. In Finder, copy files with ⌘C. Focus the remote file manager and press ⌘V.
   In the remote file manager, ⌘C copies selected files back to the Mac;
   switch to Finder and press ⌘V after “Files ready to paste” appears.

The link is for the current connection. Select it again after reconnecting.
SSH authentication and host-key checks belong to the chosen SSH tab; no second
password is requested. A temporary Python clipboard helper runs in its SSH
channel and exits when disconnected. Nothing is installed as a service and
no extra network port is opened.

The SSH account must be able to open the VNC desktop's X display. The helper
uses `DISPLAY`/`XAUTHORITY` from the SSH environment; if DISPLAY is absent,
it uses the sole local X display. With multiple displays, configure the
correct DISPLAY for the SSH account. Wayland is currently unsupported.

Transfers preserve names, file contents and nested/empty directories. Uploads
start on explicit Paste. The remote file manager handles name conflicts and
asks whether to replace existing files. Copies never move/delete originals.
Clipboard directions and view-only mode are respected. Text still works.
The limit is 64 selected roots, 10,000 total entries and 100 GB per copy.
Symbolic links, special files and names containing CR/LF are rejected.

Uploads use private `.termstead-vnc-*` staging folders in the Linux user's
home, so later Paste can still read them. Incomplete uploads are removed on
cancel. Completed caches older than seven days are removed on the next helper
start; only marked, private folders belonging to that user qualify. Downloads
use private temporary folders on the Mac and remain usable after tab close.

## Docker verification

Run `TestLab/lab.sh up`. The VNC desktop is `lab:lab` at `127.0.0.1:5901`;
its SSH endpoint is `lab@127.0.0.1:2203`, also reachable as `vnc:22` through
`lab-bastion`. The sample session is **lab-vnc-ssh**.

```sh
python3 -B TestLab/vnc/test_clipboard.py
python3 TestLab/vnc/test.py
python3 TestLab/vnc/test.py --via-bastion
```

The integration tests drive real Thunar Copy/Paste through Termstead's VNC
view, compare binary contents, preserve `test_rdp` and Unicode names, include
empty directories, verify immediate switching to Finder, clipboard focus/text,
and cancel a live upload without stopping its SSH master. They use named Mac
pasteboards, private temporary SSH credentials and disposable Linux fixtures.
Run clipboard suites sequentially; they share this desktop.
