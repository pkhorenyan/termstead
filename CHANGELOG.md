# Changelog

All notable changes to Termstead are recorded here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
the project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Server load in the status bar: CPU, memory, disk and network of the
  server in front, every three seconds, with the load average and uptime
  in its tooltip. Figures past 90% turn yellow. It reads Linux's /proc over
  the tab's own connection, through any jump hosts, in one channel that
  stays open. Settings ▸ Terminal ▸ Window ▸ Show server load turns it off.

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
