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
TestLab/macos/test.py          # native interop and file/clipboard regressions
TestLab/macos/lab.py down      # shut down; retain disk and downloaded image
```

The guest test account is `admin` / `admin`. An SSH tunnel publishes its
native Screen Sharing service on `127.0.0.1:15900`. Termstead opens a separate
session store in `.state/macos/sessions.json`; personal sessions are not used.
`~/Desktop/Termstead Files` in the guest contains binary, empty and nested
Unicode test files for manual copying in either direction.

The tests use a named pasteboard on the host and the guest's own clipboard.
The guest `clipboard.swift` utility only supplies or inspects test selections;
SSH verifies results. File contents travel through the production VNC engine
over its authenticated desktop socket. No helper or SSH access is needed for
Termstead's actual VNC file transfer feature. Generated test-run settings stay
in `.state`; no changes to the checked-in Xcode scheme are required.

The incoming transport test explicitly injects `com.apple.finder.node` in
the guest. This verifies the native sender/receiver but does **not** test an
ordinary Finder Command-C: macOS filters `public.file-url` from its clipboard
RPC. Receiving a real Finder selection still needs native drag-channel
integration. Automated local file upload and remote Finder Paste tests pass,
but Pavel reports that manual host-to-Mac file and folder copying still fails
(2026-11-13). Investigation is paused at his request. Resume with the real
Finder workflow and `test_rdp`; keep the VM disk and downloaded image across
session exits.

File-transfer diagnostics are available in macOS unified logging:

```sh
log stream --level info --predicate 'subsystem == "com.pavelkhorenyan.Termstead" AND category == "VNCFiles"'
```

Events distinguish Paste dispatch, upload requests, transport completion,
scheduled/sent Paste and cancellation. They include only attempt/revision
numbers and focus state, never file paths or clipboard contents. A sent Paste
chord is not confirmation that Finder inserted the files. Native file Paste
always uses Command-V, including with the default Linux keyboard profile.

The 2026-11-13 follow-up reproduced and fixed the wrong-modifier bug with a
failing-before/passing-after regression. The live test intentionally keeps
the default profile. Manual GUI reproduction and native drag integration are
still outstanding; headless automation must not be presented as manual
acceptance. Preserve the existing VM and cache for the next interactive run.
