# Changelog

All notable changes to Termstead are recorded here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
the project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Remote desktops (RDP) in tabs. A session is SSH or RDP, chosen at the top
  of the session form; an RDP session opens as a tab like any other, in any
  pane, through its jump hosts if it has them — ssh carries the desktop from
  the last hop, with host keys and passwords asked in the tab's terminal as
  usual. The engine is FreeRDP, in a sandboxed process of its own with no
  network access.
- The desktop fits the tab and follows it when the window is resized or the
  pane changes, sharp on Retina screens (Windows at 200%), or keeps a fixed
  size scaled to fit. Zoom, 100–300%, is set per session and changed in the
  tab with ⌘+, ⌘− and ⌘0: Windows redraws sharply at the larger size;
  for Linux servers, which ignore it, turn Sharp off and the picture is
  enlarged instead.
- Keyboard and mouse: keys by position, as Microsoft's client sends them,
  with ⌘ shortcuts kept for Termstead; ⌘C, ⌘X, ⌘V, ⌘A, ⌘Z and ⇧⌘Z in a
  remote desktop are Ctrl and the same key there; Send Ctrl+Alt+Del and Send
  Windows Key in the Session menu and the tab's menu; the wheel and
  trackpad scrolling both ways. The pointer takes the server's shapes —
  a text cursor over a field, resize arrows at a window's edge — at the
  size they have on the desktop.
- The server's certificate is checked against macOS's trust; one macOS does
  not trust is asked about in the tab, with its fingerprint, and remembered
  once trusted. A certificate that changed is asked about as a change.
  A server that offers only the old RDP security, which has no
  certificate to check, is not logged in to.
- A login the session has no password for, or the server refuses, is asked
  for in the tab, with Save to Keychain.
- Text and files copied on either side can be pasted on the other: files
  copied in Finder paste into Explorer, and files copied there paste into
  Finder once you switch to it, with progress in the status bar. The Mac's
  clipboard reaches a remote desktop only while you are typing in it, and
  a password copied from a password manager only when you press ⌘V there.

### Changed

- A new app icon.

### Fixed

- Closing a connected tab, reconnecting a session with Save & Reconnect, or
  stopping a tunnel left its ssh behind as a defunct process until
  Termstead quit. They are now cleaned up as they exit.

## [0.6.0] - 2026-10-20

### Added

- Port forwarding: local (`-L`), remote (`-R`) and SOCKS (`-D`) tunnels,
  set up from a session's context menu (Port Forwarding…) in the sidebar or
  on its tab, through the session's jump hosts. As in MobaXterm it is an
  option of its own: connecting opens a shell and no tunnels, and Start Port
  Forwarding in the context menu runs each tunnel on a connection of its
  own, with no tab. Stop Port Forwarding ends them all. If ssh needs an
  answer (a host key, a password not saved), that connection opens as a tab.
- Each tunnel shows whether it really opened, and can be stopped and
  started on its own while port forwarding runs. Stopping one also ends the
  connections already open through it, such as a browser's. A port already
  taken on the Mac reads "Port 8080 is already in use on this Mac".
- Open in Browser for a running local tunnel, in the Port Forwarding
  window and the status bar's list: its address on this Mac, https when it
  leads to port 443.
- A count of running tunnels in the status bar. Clicking it lists every
  session's tunnels with their state, Stop / Start, and Stop All.
- Import from ~/.ssh/config brings a host's LocalForward, RemoteForward and
  DynamicForward into the session, and so does the Port Forwarding window
  for sessions imported earlier.
- Duplicate, in a session's context menu: a copy right after it, named
  "… copy", with its name open for editing as in Finder. It connects as the
  original does — saved passwords come along — while its jump hosts and
  tunnels are its own, so deleting one session leaves the other's intact.
- A ⇄ beside the name of a session with port forwarding on: green while a
  tunnel runs, red when one failed, grey with all of them stopped.
- A right-click on the sidebar's empty space opens a menu: New Session,
  New Group, Quick Connect and Import from ~/.ssh/config.

### Changed

- Termstead no longer opens the tunnels a `~/.ssh/config` names by itself:
  it could neither show nor stop them, and a second tab of the session
  failed on each one. Import them into the session (see above).

### Fixed

- Back from the SFTP tab, the session list is where it was scrolled to,
  not at the top.
- In the Nord theme the text fields were the same color as the form around
  them; they are darker now.

## [0.5.0] - 2026-10-17

### Added

- The sidebar can be hidden, leaving the window to the terminals: View ▸
  Hide Sidebar (⌃⌘S), or the button beside the window's name. The choice is
  remembered.
- With the window split, a tab dragged off its strip follows the pointer
  anywhere over the panes, while the tab itself waits, faded, in its slot.
  Back over its own strip it slides along it as before.
- Two more dark themes: Nord, the calm grey-blue palette many people know
  from their editors, and Synthwave, 80s neon on deep violet.
- About Termstead links to the program's website and to its source on
  GitHub.

### Fixed

- In the session, group and quick-connect forms, the accent ring follows
  the field being typed in; it used to stay on the first field when Tab
  moved on.
- The Homebrew cask declares its macOS requirement as `depends_on macos:
  :sonoma`; newer Homebrew warned about the old `">= :sonoma"` form.

## [0.4.0] - 2026-10-14

### Added

- Panes: the terminal area splits into two panes side by side (⌘D), two
  stacked (⇧⌘D) or four, from buttons beside the gear or the View menu.
  Each pane has its own tab strip, with everything a strip has; the
  dividers can be dragged, and a double-click evens them out. A tab moves
  to another pane by dragging it onto that pane's strip, or with Move to
  Pane in its menu. The other panes are dimmed, and a quiet accent line
  sits under the focused pane's tabs. ⌘] and ⌘[ move between panes, and the status bar,
  the SFTP panel, Find and the menus follow the focused one. Going back to
  fewer panes closes nothing, and Reopen tabs at launch brings the layout
  back too.
- Broadcast input (⌥⌘I, or the antenna beside the layout buttons): what is
  typed or pasted in one pane goes to every visible pane's tab in front.
  The antenna on a pane's tab strip leaves that pane out, or brings it
  back. Every pane that takes the input has a yellow line under its tabs,
  and the status bar says how many there are. Closed tabs, empty panes,
  mouse clicks in programs such as vim, and the terminal's own replies to
  the program are never sent on; going back to one pane turns it off.

- Server load in the status bar: CPU, memory, disk and network of the
  server in front, every three seconds, with the load average and uptime
  in its tooltip. Figures past 90% turn yellow. It reads Linux's /proc over
  the tab's own connection, through any jump hosts, in one channel that
  stays open. Settings ▸ Terminal ▸ Window ▸ Show server load turns it off.

### Changed

- The terminal font's ligatures are off unless turned on in Settings ▸
  Appearance ▸ Ligatures: `->`, `!=` and `=>` read as typed, and fast
  output is cheaper to redraw. Until now they were always on.

### Fixed

- ⌘W closes the tab in front, as Session ▸ Close Tab says. It used to close
  the main window instead and leave Termstead running with no window: the
  stock File ▸ Close had the same shortcut and won. Settings and the forms
  still close on ⌘W.

## [0.3.1] - 2026-10-13

### Added

- The session tree works from the keyboard once a row is clicked, as
  Finder's list does: ↑ and ↓ move through the Pinned strip and the tree
  (⇧ extends the selection), → opens a group or goes into it, ← closes it
  or goes up, Return connects every selected session or opens and closes a
  group, and Esc hands the keyboard back to the terminal. ↓ in the search
  field goes to the first session found.

### Changed

- The status bar shows the terminal's size alone, without
  "UTF-8 · xterm-256color": every tab is the same on both counts.

### Fixed

- Reopen tabs at launch reopened nothing: Termstead declared sudden
  termination, so macOS ended it on Quit before the open tabs were written
  down. It no longer does, and is not ended silently in the background
  either, which would have dropped live ssh sessions.

## [0.3.0] - 2026-10-13

### Added

- A context menu on each tab: Reconnect, Duplicate Tab, Session Settings…,
  Close Tab, Close Other Tabs and Close Tabs to the Right. Closing several
  live tabs asks once.
- ⇧⌘] and ⇧⌘[ show the next and the previous tab (Session ▸ Show Next Tab /
  Show Previous Tab), wrapping round at the ends.
- Settings ▸ Terminal ▸ Window ▸ Reopen tabs at launch: the tabs open when
  Termstead quits connect again the next time it starts, in the same order
  and with the same one in front. Off unless turned on.

### Changed

- A dragged tab stops at the ends of the strip instead of sliding past the
  first slot or over the "+" button.
- A closed tab's icon is struck through, the way macOS marks something
  switched off, rather than only fading — which read as a color gone wrong.

### Fixed

- Escape in Session settings closed the form and opened it straight away
  again, in a window nothing could close, while the rest of the app ignored
  every click.

## [0.2.0] - 2026-10-12

### Added

- Tabs can be dragged along the strip to put them in another order; held
  near either end of a strip that scrolls, a tab scrolls it along. The middle
  mouse button closes a tab.

### Changed

- A tab shows its session's icon where the status dot was, in its group's
  color as in the sidebar; a closed tab fades instead of turning red, since red
  and green are group colors too. A quick connection gets the shell icon.

### Fixed

- With more tabs than fit, the strip pushed the sidebar off the window's left
  edge and squeezed every title out. It scrolls now — with a mouse wheel or a
  vertical swipe anywhere over it, too — and keeps the tab in front in view;
  a long title is shortened in the middle.

## [0.1.1] - 2026-10-12

### Fixed

- The icon picker in the session form came up empty: the space was there, the
  icons were not.

## [0.1.0] - 2026-10-08

The first public release, 0.1.0.

### Added

- Sessions in a tree of groups and subgroups: colors that sessions inside take
  on (a palette or any custom color), an icon per session, pinned sessions,
  search, and drag and drop to reorder or move several rows at once.
- Connections through the system OpenSSH, one tab each: the agent,
  `~/.ssh/config`, `known_hosts` and `ProxyJump` work as in Terminal.
- Jump-host chains of any length; a jump host can be a saved session.
- Passwords and key passphrases in the login Keychain, answered for ssh through
  a helper and handed only to the host they were saved for.
- The SFTP tab over the terminal's own connection: browse, follow the
  terminal's folder, upload and download (drag and drop both ways), rename,
  delete, create folders, and open a remote file in a Mac app with changes
  saved back. The sidebar turns to it once a connection has logged in (unless
  the server has no SFTP; Settings ▸ Terminal ▸ Window turns this off).
- Import of hosts from `~/.ssh/config`.
- Find in the terminal output (⌘F, ⌘G, ⇧⌘G), the match marked in a solid
  color that stands out in every theme, and a configurable scrollback.
- Keyword highlighting in output the server left uncolored: standard (errors,
  warnings, success, IP addresses, URLs) or network (plus interface names,
  up/down and MAC addresses).
- Six themes, Graphite (dark) by default and following macOS light and dark
  mode if chosen; any monospaced font; copy on select; a confirmation before
  pasting several lines; Option as Meta; a confirmation before closing a live
  connection.
- Quick connect by address (⌘K), and closed tabs that keep their output and
  reconnect on Return.
- A text size per tab: ⌘+ and ⌘− (⌘= too) zoom the tab in front, ⌘0 returns
  it to the size set in Settings.
- The sidebar on the left or the right of the window (Settings ▸ Terminal ▸
  Window); its Sessions / SFTP tabs keep to the window's edge.
- Updates through Sparkle: a check once a day and Termstead ▸ Check for
  Updates…; every update is verified against the project's signing key before
  it is installed.
