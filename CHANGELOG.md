# Changelog

All notable changes to Termstead are recorded here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
the project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
