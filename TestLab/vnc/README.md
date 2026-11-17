# VNC file access over SFTP

Termstead's VNC tab can browse and transfer files over a separate SSH/SFTP
connection. This works with macOS and Linux hosts that offer SSH access; no
helper is installed on the remote desktop. VNC still carries the screen and
text clipboard.

1. Enable SSH/SFTP on the VNC computer and save an SSH session in Termstead.
2. In the VNC session settings, choose that SSH session under **File access**.
   The VNC and SSH passwords or keys are independent.
3. Open the VNC tab and select **SFTP** in the sidebar. The SSH file connection
   opens in the background without an extra terminal tab.
4. Copy files in Finder, select the destination folder in the sidebar, then
   choose **Paste** or press ⌘V with the file list focused. For the other
   direction, select a sidebar file, choose **Copy** or press ⌘C, wait for
   its download to finish, then paste into Finder. Drag and drop and
   Upload/Download are also available.

The saved SSH settings supply authentication, host-key checks and jump hosts.
The background connection ends with the VNC tab. SSH login questions appear
inside its terminal pane. File transfer depends on SSH/SFTP availability and
does not use the VNC desktop's own file-manager clipboard.

The earlier experimental X11 clipboard bridge remains in the test harness
below, but is no longer the app's default file transfer path.

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
and cancel a live upload without stopping its SSH master. Additional checks
open a background SSH connection without creating a tab, close it with VNC,
and click Paste in the real Thunar menu on its first opening (including
send-only clipboard mode). They use named Mac
pasteboards, private temporary SSH credentials and disposable Linux fixtures.
Run clipboard suites sequentially; they share this desktop.
The runner clears expired file-URI selections from its own deleted fixture
directories before handing the desktop back. Valid files, text and unrelated
clipboard selections are preserved. The app also ignores expired selections
during automatic clipboard inspection, so reconnecting cannot open a dialog
just because a previously copied file was deleted.
