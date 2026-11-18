# Native macOS VNC lab

An opt-in Apple Silicon VM for testing native Screen Sharing, separate from
the Linux/TigerVNC Docker lab. All VM state lives in **`TestLab/.state/macos`**
inside this checkout. Never put the disk or image cache in `/tmp`: a reboot
can remove them. `.state` is gitignored; keep it when stopping the lab.

The pinned guest is macOS 26.6.2, image digest
`sha256:eeec54bfe1f076e27786c5d92b89187a05b1d109b5071eb2dcdf02d596e34640`.
The download is approximately 23.88 GB; every blob is checked against its
SHA-256 digest before a loopback-only registry serves it to Tart. Downloads
resume from completed ranges. The guest uses 2 CPUs and 4 GiB RAM, host-only
networking, no shared host folders, and no Tart clipboard integration.

Install the verified Tart 2.41.1 app at
`TestLab/.state/macos/tool/tart.app`. The release's `tart.tar.gz` SHA-256 is
`e680a734febccfce7d4e910c1f7f13fc3b00f19a181c945e2d746de3214c32c2`.
The lab sets its own `TART_HOME` and disables automatic pruning; it does not
manage the user's `~/.tart` VMs.

```sh
TestLab/macos/lab.py up --open  # fetch once, boot, provision, open Release app
TestLab/macos/lab.py status
TestLab/macos/test.py          # native text clipboard and SFTP file checks
TestLab/macos/lab.py down      # shut down; retain disk and downloaded image
```

The guest test account is `admin` / `admin`. An SSH tunnel publishes its
native Screen Sharing service on `127.0.0.1:15900`. Termstead opens a separate
session store in `.state/macos/sessions.json`; personal sessions are not used.
File transfer in Termstead uses a separate SSH/SFTP login configured inside
its VNC session. The Files sidebar browses the Mac over that connection; VNC
Screen Sharing handles the desktop and text clipboard. The VM exposes SSH for
SFTP checks. The opt-in test suite uses named pasteboards to verify Unicode
text, focus behavior, and file and folder transfers through the SFTP panel.
Generated test-run settings stay
in `.state`; no checked-in Xcode scheme changes are needed.

Keep the VM disk and downloaded image under `TestLab/.state/macos` for future
manual tests. `lab.py down` shuts the VM down without deleting either one.
