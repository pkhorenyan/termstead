# CLAUDE.md

Everything about developing Termstead: architecture, commands, conventions,
design decisions and the traps that have already cost time. `README.md` is for
people who use the app; keep development material here, not there.

> **Keep the history in `CHANGELOG.md`, not here.** After finishing a significant
> task, add an entry to the matching section (Added / Changed / Fixed / Removed)
> under `Unreleased`. Commit every meaningful change and every new feature.

## What this is

Termstead is a native macOS SSH client — a MobaXterm replacement — recreated
from a design mockup. The mockup lives in `VisualReference/`, which is kept
locally and not in the repository (it is gitignored). A tab is the system
`/usr/bin/ssh` in a pseudo-terminal, drawn by SwiftTerm. The session tree is
saved to `~/Library/Application Support/Termstead/sessions.json`, secrets live
in the login Keychain, and `termstead-askpass` hands them to ssh. There is no
SSH code of our own: everything ssh can do (agent, config, known_hosts,
ProxyJump) comes from OpenSSH, and `SSHLaunch` only writes the config it runs
with.

**Names.** The app was developed as "Shellbox"; that name survives only in
the private pre-release history. Everything says Termstead: the bundle, the
bundle id `com.pavelkhorenyan.Termstead` (and with it the UserDefaults domain),
the Keychain service of the same name, the Application Support folder,
`termstead-askpass`, the Xcode project, targets and Swift module. **The data
identifiers are fixed from the first release** — renaming any of them loses
users' sessions, settings or saved passwords. Development launch flags keep
their short `-sb-` prefix. The Help menu has no items of its own — there is no
help book — only macOS's menu search.

## Build and run

```sh
brew install xcodegen                   # once
xcodegen generate                       # after adding, renaming or deleting a file
xcodebuild -project Termstead.xcodeproj -scheme Termstead \
           -configuration Release -derivedDataPath build build
open build/Build/Products/Release/Termstead.app
```

- **SwiftTerm is vendored** in `Vendor/SwiftTerm` — 1.11.2, the library
  target only, with patches listed in `Vendor/SwiftTerm/PATCHES.md`. It is held at 1.11: 1.12 added Metal shaders, which
  need Xcode's separately downloaded Metal Toolchain to build. Change it only
  through a new entry in PATCHES.md, and keep it free of warnings like the rest
  of the build.
- **Sparkle comes through Swift Package Manager** (a binary framework), so the
  first build fetches it from GitHub. If macOS then asks for the login keychain
  password on behalf of xcodebuild for "github.com", deny it: the repository is
  public, and a stored GitHub login is only being offered.
- `Termstead.xcodeproj` is generated from `project.yml` and is **not** committed.
  Adding a source file means re-running `xcodegen generate`.
- The build must stay free of warnings as well as errors.
- **The version is written in two places**: `MARKETING_VERSION` in
  `project.yml` and the version badge under the title of `README.md` (its
  image URL and its alt text). Bump both.
- Hand Pavel the **Release** build. Debug is materially slower for interaction
  work (drag start measured 105 ms in Debug against 67 ms in Release).
- **Launch it for him with the sample data**: quit the running copy, then
  `open build/Build/Products/Release/Termstead.app --args -sb-sample YES`. He
  asked for every fresh build to come with something to experiment on. The
  sample tree is in memory only and never touches his real `sessions.json`.

### Debug routes

`open build/Build/Products/Release/Termstead.app --args -sb-route <name>` lands
straight on a screen: `newSession`, `newGroup`, `sessionSettings` (with
`-sb-session <name>`), `groupSettings` (with `-sb-group <id>`), `quickConnect`,
`empty`, `appearance`.
`-sb-color-picker YES` opens the custom color dialog over the main window.
`-sb-connect a,b,c` opens those sessions' tabs at launch (the first in front), `-sb-sidebar files`
shows the Files tab, and `-sb-ssh-prefix <file>` puts that file's ssh options
ahead of the generated config (trust settings for a throwaway local sshd; start
one with `Subsystem sftp /usr/libexec/sftp-server` to look at the Files tab).
Appearance can be forced with `-appearance.theme <id> -appearance.followSystem NO`.
Arguments live in the volatile domain and never persist.

**A launch route keeps the tree in memory** — the sample data, or nothing for
`empty` — and never reads or writes Pavel's real `sessions.json`. So do
`-sb-sample YES` and a test run. `-sb-store <path>` points at another file, and
wins over a route's sample tree, so a route can open a form on it. See
`SessionStorage.forThisLaunch`. Anything that launches the app for testing must
use one of these.

**The Debug menu** (Load Sample Data, Add Test Lab Sessions, Clear All
Sessions — the last without asking) exists only in Debug builds or when any
`-sb-*` flag is given (`DevelopmentLaunch`). Users never see it.

How each screen is reached in normal use:

| Screen | How to reach it |
|---|---|
| Main window | default |
| First launch | a fresh install, `-sb-route empty`, or Debug ▸ Clear All Sessions |
| Connect | double-click a session, its context menu, or ⌘O |
| New session | ⌘N, "Session" in the sidebar footer, or a group's context menu (New Connection…) |
| Session settings | a session's context menu, or ⌘I |
| New group | ⇧⌘N, "Group" in the sidebar footer, or a group's context menu (New Subgroup…) |
| Group settings | a group's context menu |
| Quick connect | ⌘K (the first-launch screen's own field, otherwise a form); ⌘T for a new tab |
| Settings | ⌘, or the gear at the trailing end of the titlebar |
| Files (SFTP) | the SFTP tab on the sidebar's left rail |

The forms are windows of their own, not sheets, so they can be moved aside. A
group's color and a session's icon are set in them; the sidebar only shows them.

## Tests

```sh
xcodebuild -project Termstead.xcodeproj -scheme Termstead -derivedDataPath build test
```

`TermsteadTests` (Swift Testing) is hosted in the app, and so runs in **Debug**,
which is built without the hardened runtime: library validation otherwise
refuses the ad-hoc-signed test bundle. It covers persistence, the drop
arithmetic, `SSHLaunch` (including a check that `ssh -G` reads the generated
config as intended), askpass prompt matching and the Keychain store.

`ConnectionIntegrationTests` starts `/usr/sbin/sshd` on 127.0.0.1 as the
current user, in a temporary directory, and connects with the app's own code:
key auth through a jump host, `exit` and reconnect, a passphrase answered from
the Keychain, and a refused stored passphrase falling back to the terminal. The
Keychain tests use a service of their own and delete their items. A non-root
sshd cannot check system passwords, so those tests cover keys only.

`TestLabTests` cover the rest, **passwords included**, against the Docker lab
in `TestLab/`. They are skipped when nothing listens on 127.0.0.1:2202, so a
run without the lab still passes. They use the sample data's own "Test lab"
sessions, a known_hosts file of their own and a throwaway Keychain service.

### The test lab

SSH servers in Docker to connect to — directly, through one jump host, and
through two. Docker Desktop must be running.

```sh
TestLab/lab.sh up        # keys if missing, build, start
TestLab/lab.sh down
TestLab/lab.sh forget    # drop the lab's host keys from ~/.ssh/known_hosts
```

```
127.0.0.1:2201 ─▶ direct                     lab-direct, -password, -passphrase
127.0.0.1:2202 ─▶ bastion ─▶ app             lab-app-1-jump, lab-app-password
                  bastion ─▶ middle ─▶ db    lab-db-2-jumps, lab-db-2-jumps-typed
```

User `lab`, password `lab`, key `~/.ssh/termstead-lab` (and
`~/.ssh/termstead-lab-passphrase`, passphrase `lab`). The sessions are in the
sample data's "Test lab" group, or Debug ▸ Add Test Lab Sessions puts them into
the saved list. The first connection to each server asks to trust its host key
in the terminal, as ssh does. Each home folder is seeded with files for the
Files tab: logs, a 20 MB file, odd names, symlinks, a read-only file and a
folder that cannot be opened (`TestLab/entrypoint.sh`).

**The README's screenshots** come from `TestLab/screenshots/shoot.sh`
(`stage`, `open`, `clean`). It uses the sample sessions without the test lab,
opens four tabs, and makes them look like real servers:
- `prefix.conf` maps each sample address onto a lab container, `prod-web-02`
  through both jump hosts;
- a demo script per server prints plausible output, then hands over to a shell
  with the matching prompt;
- the Files tab follows `prod-web-01` into a staged web root.

Nothing in them may show a real host, name or path. The sample host `nas`
never gets a color.

## Releases

```sh
scripts/release.sh 0.2.0
```

- **What it does.** Sets the version, builds an archive and exports it for
  Developer ID. It notarizes and staples the app, packs a DMG, then signs,
  notarizes and staples that too. It signs the DMG for Sparkle and writes
  everything into `releases/<version>/` (gitignored): `Termstead.dmg`,
  `appcast.xml`, `notes.html` and the Homebrew cask `termstead.rb`.
- **Apple can hold a submission for days** (the first ones were held a week, and
  cleared after a thread in the developer forums' Notarization section). A script
  left waiting that long gets killed with the session that started it. Check
  `xcrun notarytool history --keychain-profile termstead-notary` instead, and
  once the submission is accepted, `scripts/release.sh <version> --resume` reuses
  `releases/<version>/export`: Gatekeeper already passes that build online, so
  it is stapled rather than sent again, and the script carries on with the DMG.
- **Nothing is published by it.** Publishing is manual and happens only when
  Pavel says so:
  1. Commit and tag `v<version>`, then push.
  2. Create a GitHub release on that tag with `Termstead.dmg` **and**
     `appcast.xml`.
  3. Copy the cask to `Casks/` in `pkhorenyan/homebrew-tap` and push it.
- **Versions.** The version lives in `project.yml` and in README's version
  badge; the script sets both. The build number (`CURRENT_PROJECT_VERSION`)
  is what Sparkle compares, so it only ever goes up. The `Unreleased` section of
  CHANGELOG.md becomes the version's section and the release notes.
- **Needs, on the Mac that releases:**
  - the "Developer ID Application" certificate (team `YHQLC8PBT3`);
  - notarytool credentials saved as the keychain profile `termstead-notary`;
  - Sparkle's EdDSA private key in the login keychain. Its public half is
    `SUPublicEDKey` in Info.plist.
  - macOS asks once whether `codesign` and `sign_update` may use those keys.
- **The EdDSA key cannot be replaced** without breaking updates for everyone
  already installed. Keep a backup of it: `generate_keys -x <file>`, from
  `build/SourcePackages/artifacts/sparkle/Sparkle/bin/`.
- **The appcast is a release asset.** `SUFeedURL` is
  `releases/latest/download/appcast.xml`, so it always reads the newest
  release's copy. A release without it strands every installed copy on the
  previous version.
- **The updater never starts in a developer's launch** (`AppUpdater`: Debug
  builds, tests, any `-sb-*` flag). Otherwise it would offer to replace the
  build under test with the published one.

## Module map

| Path | Holds |
|---|---|
| `Sources/TermsteadApp.swift` | App entry, scenes, commands, `Metrics` |
| `Sources/AppState.swift` | Route (which form is up), quick-connect text, `DevelopmentLaunch` |
| `Sources/AppUpdater.swift` | Sparkle: the daily check and "Check for Updates…" |
| `scripts/release.sh` | Builds a signed, notarized release with its appcast and cask |
| `Sources/Model/` | `SessionStore` (the tree and all editing), `Session`, `SessionGroup`, `TreeNode`, row models, drag payloads, sample data, `SessionPersistence`/`SessionStorage` |
| `Sources/SSH/` | `SSHLaunch` (session → ssh_config), `Connection` (one tab: process + terminal view), `ConnectionStore` (the tabs), `KeychainStore`, `AskpassServer` + `AskpassMatcher`, keyword highlighting, `~/.ssh/config` import |
| `Sources/SFTP/` | `SFTPClient` (`sftp -b` over the tab's connection master), the `ls -la` parser, `FileBrowser` (the Files tab's state per tab, transfers, open-and-edit) |
| `Helpers/Askpass/` | `termstead-askpass`, the `SSH_ASKPASS` helper, installed in `Contents/MacOS` |
| `Shared/` | The askpass wire format, compiled into both the app and the helper |
| `Tests/` | `TermsteadTests` |
| `TestLab/` | Docker SSH servers for manual and automated testing (`lab.sh`), and the screenshot kit in `screenshots/` |
| `Sources/Theme/` | `Theme` tokens, the six themes, `RGB`, `ThemeStore`, `SBFont` |
| `Sources/Views/Sidebar/` | The tree: rows, the AppKit mouse layer, the resize handle, and `SidebarTabRail` (Sessions / SFTP down the left edge) |
| `Sources/Views/Terminal/` | Tab bar, find bar and `TerminalPane` (mounts the active connection's SwiftTerm view, applies the theme) |
| `Sources/Views/Sheets/` | Session and group forms plus their controls, and the color picker. They are *windows* now, not sheets; the names are historical |
| `Sources/Views/Files/` | `FilesPanel`, the sidebar's Files tab |
| `Sources/Views/Settings/` | The Settings window: appearance and terminal behaviour |
| `Sources/Window/` | `WindowConfigurator` (window chrome, titlebar accessory, traffic lights) `FormWindow` (the forms, as movable child windows) and `AppModal` (app-modal running for the forms and Settings) |
| `Sources/Components/` | Reusable controls, `ThemeSwatch`, `PromptGlyph`, `FlowRow` |
| `Resources/` | `Info.plist`, bundled fonts and their licences, asset catalogue |
| `docs/images/` | The README's screenshots |

`SessionStore` is the centre of gravity: the tree, the flattening that turns it
into sidebar rows, and every mutation. Views hold no tree logic — rows arrive
with indentation, inherited colour and drop targets already resolved.
`ConnectionStore` is its runtime counterpart: which sessions have live tabs is
read from there, never stored on `Session`.

## How a connection works

- **The command.** `SSHLaunch` turns a session into an ssh_config written for
  that one connection (0600, in a private temporary directory, deleted when the
  tab closes): a `Host` block per jump host and for the target, chained with
  `ProxyJump`, each with its own user, port and key or password preference.
  The user's `~/.ssh/config` and the system config are included after those
  blocks, so their settings still apply to anything the session does not set —
  and the blocks are named after the hosts as typed, so an alias such as
  `bastion-01` still picks up the `HostName` the user's config gives it.
- **A jump host** is `user@host:port`, or the name of a saved session, which then
  connects the way that session does. "Same as session" uses the target's
  authentication.
- **Keys** follow ssh's rules: the agent, the user's config and the default keys
  all work. A session set to a key uses exactly that key (`IdentitiesOnly`),
  unless it still carries the default path and that file does not exist.
- **Passwords and passphrases.** On Save, what was typed goes to the Keychain.
  When ssh asks, it runs `termstead-askpass`, which asks the app over a Unix
  socket. A password is handed over only for the exact `user@host` it was saved
  for; a key's passphrase belongs to the key file, so one entry serves every
  session using it. Each stored secret is offered once per hop that uses it —
  if ssh asks again, the stored value was wrong, and the prompt appears in the
  terminal as usual.
- **Host keys** are ssh's business: the first connection to a server asks yes/no
  in the terminal, against the real `known_hosts`.
- **Closed tabs** keep their output. Press Return to reconnect.
- **The Files tab** rides the same connection (see the pitfall on
  `ControlMaster` below), so it never asks for a password twice.
- **Login** is when ssh's control socket (`cm` in the work directory)
  appears: ssh opens it only once logged in to the target, after every jump
  host, host-key question and secret. `Connection` watches the directory with
  a `DispatchSource` and calls `onLogin`; `AppState.showFiles(afterLoginOf:)`
  then loads the first folder and turns the sidebar to SFTP — not for a
  server without SFTP, and not if the tab is no longer in front. The
  screenshot kit turns it off (`-files.showAfterLogin NO`) to keep the tree.

## Conventions

- **Swift 6 strict concurrency** (`SWIFT_STRICT_CONCURRENCY: complete`) and
  `SWIFT_UPCOMING_FEATURE_EXISTENTIAL_ANY`. Protocol types need `any`.
- Observation (`@Observable`, `@MainActor`), not `ObservableObject`.
- **Comments say why, not what.** Most comments in this codebase exist because
  something non-obvious was tried and failed; keep that reason in the comment
  rather than describing the line below it.
- Colours are `RGB` tokens from `Theme`, never literals and never system colours.
  Group colours carry a separate light-theme variant (`GroupColor`) chosen to
  clear WCAG 4.5:1.
- Fonts come from `SBFont`, which addresses every weight by PostScript name —
  `.weight(.medium)` on the base family silently synthesises a weight instead of
  using the real face.
- Layout constants live in `SidebarMetrics` and `Metrics`, not inline.
- Write English in code, comments and documentation.
- Measure before claiming a speed-up, and say what was measured.

## Deliberate departures from the mockup

The mockup is still the spec for most screens, but not for these. A pass that
diffs the app against it will read all of them as regressions.

- **The sidebar is denser**, and follows a second reference Pavel supplied: no
  tree guides, no per-row session counts or "+" buttons — a group's context
  menu offers "New Connection…" and "New Subgroup…" instead — bare glyphs
  rather than tiles behind the icons, and session names tinted with their
  group's color. Rows are 35pt for a session and 24pt for a group, and the tree
  indents by 8pt per level from a 14pt base.
- **The sidebar is resizable**, 230–434pt including its 34pt tab rail
  (double-click the divider to reset), and its width is remembered. The rail
  switches between Sessions and SFTP, as MobaXterm does.
- **The sidebar can sit on the right** (`ThemeStore.sidebarSide`, Settings ▸
  Terminal ▸ Window). The rail keeps to the window's edge, and the divider and
  the resize strip keep to the edge facing the terminal. The setting is on the
  Terminal tab because Appearance already fills the window.
- **The session form** is a single 1170pt column in the mockup, which cannot fit
  on an 800pt window. The same fields run in two columns here — connection on
  the left, authentication and the jump chain on the right. The form is a fixed
  820×648 and only the right column scrolls, so adding jump hosts never pushes
  the footer buttons out of reach.
- **There is no toolbar.** The mockup drew a 50pt bar carrying a quick-connect
  field, "New session" and "Theme". Sessions are opened from the tree and
  created from the sidebar footer, ⌘N or a group's context menu; "Theme" became
  a gear at the trailing end of the titlebar, opening Settings. Connecting by
  address lives on the first-launch screen, which is built around it, and
  behind ⌘K / ⌘T.
- **Both ends of the titlebar are accessory views**, so it keeps its standard
  height: the app name leading, the gear trailing (see "The titlebar" below).

## Design notes

### Themes

`Theme` carries the full set of semantic tokens. Graphite is written out value
for value from the reference and is what fidelity is measured against; the other
five are expanded by `Theme.derived(...)` from the nine tokens the Settings
screen publishes, using ratios calibrated so that feeding it Graphite's nine
seeds reproduces Graphite exactly.

### Group colors

`GroupColor.palette` carries two values per swatch. The pastels are tuned for
the dark themes; as text on a light sidebar they fall to roughly 3:1, and
darkening them enough to read (a 0.73 mix towards the text color) drains so much
chroma that the eight stop being distinguishable. The light themes therefore get
their own dark-on-light variants, the same way each theme defines its own ANSI
colors. Every variant clears 4.5:1 against both light themes' sidebar and
selected-row backgrounds — re-check that if you change one. Custom colors derive
theirs the same way (see the color-id pitfall).

### The sidebar's mouse layer

Clicks and drags in the tree are handled by `RowInteraction`
(`Sources/Views/Sidebar/RowInteractionLayer.swift`), a small `NSView` mounted as
an `.overlay` on every row — not by SwiftUI gestures.

The reason is latency. A row used to carry a `Button` for its primary action and
`.onTapGesture(count: 2)` on the same view. SwiftUI resolves those exclusively,
so the single click could not fire until the double-click window had passed.
Measured on a stand-alone harness: **357 ms** for that pair against **3 ms** for
the button alone and **0.8 ms** for the AppKit layer. No CPU is burned during
the wait, which is why every profiler said the sidebar was idle while it felt
unusable. `NSEvent.clickCount` is known on the first `mouseDown`, so both
actions run on the press with nothing to wait for.

| Row | Click | Double-click | Drag source | Accepts |
|---|---|---|---|---|
| Session | select | connect | yes | above / below |
| Group | select | expand / collapse | yes | above / below / inside |
| Top-level header | select | expand / collapse | yes | inside |
| Pinned | select | connect | no | nothing |

There is **one icon column per depth**, shared by groups and sessions: a group's
folder sits in the same 18pt box as a session's glyph, at
`SessionStore.indentBase + depth * indentStep` (14 + depth × 8). The disclosure
chevron hangs in the indentation to the *left* of that column rather than in
front of it, which is why `indentBase` exists at all — it is the gutter the
chevron needs at the shallowest level, and at 14 it is exactly
`SidebarMetrics.chevronInset` with nothing to spare. Going lower makes that
spacer's width negative, SwiftUI clamps it to zero, and the section headers
silently stop lining up with the icons beneath them. Putting the chevron in
front instead pushes every row right by its width, and then a session (which
has no chevron) has to reserve the same space or its icon lands *left* of its
own parent folder.

The chevron stays a SwiftUI button underneath the layer, which hands its strip
back through `hitTest` (`RowInteraction.passthrough`). Right-clicks select the
row (`onContextClick`) and then pass through, so `.contextMenu` is still
SwiftUI's — and that menu is the only way to pin a session.

### Dragging

Sessions and groups are dragged with the mouse. The vertical position inside a
row decides what happens: on a session the upper and lower halves insert above or
below it; on a group the outer quarters do the same while the middle half moves
the item inside, the split `NSOutlineView` uses. The strip under the last row
pulls a group out to the top level.

`SessionStore.drop(_:to:)` takes a `DropTarget` — a parent and a child index — so
rows can be reordered within a group and not only re-parented. `canDrop(_:to:)`
holds the rules: a group cannot land inside its own subtree, a session always
needs a group, and landing on either side of your own slot is refused so nothing
flickers. Moving down inside one parent shifts the index by one, because
detaching the row first closes the gap.

Drawing the drop indicator inside the `NSView` keeps a drag from touching
SwiftUI state, so crossing rows invalidates nothing. Hovering over a collapsed
group for ~450 ms opens it, and a drag near the top or bottom edge scrolls the
list.

### Performance

The sidebar is not CPU-bound: ~10 µs of app CPU per pointer move and ~0.2–0.5 ms
per group expand on the sample tree, Release build. When it feels slow, look for
something waiting rather than something computing — the 357 ms above cost
nothing and dominated everything. Keep a measuring workload state-neutral: a
script that drags hosts around leaves the tree different on every run, so the
traces are not comparable.

`SessionStore.flattened` is walked once per render and read for both the rows
and the pinned strip; the lighter `sessionIndex` (no rows, and no read of
`collapsedGroupIDs`) serves the tab strip and status bar, so expanding a group
does not invalidate them.

### The titlebar

Every window names itself through a leading `NSTitlebarAccessoryViewController`
installed by `WindowConfigurator` (`titlebarTitle` / `installTitle(on:text:)`),
with the gear as a second, trailing accessory on the main window. No window
draws a bar of its own: fake bars under the titlebar hit the 28pt painting trap
below. `TrafficLightCentering` has nothing to do at the standard 28pt, but it
stays: it keeps the buttons centred if a window ever asks for a taller bar.

### Typefaces

JetBrains Mono and IBM Plex Sans are bundled under the SIL Open Font License 1.1.
The license texts travel with them in `Resources/Licenses/` and are copied into
the app bundle. The static TTFs register Medium and SemiBold as separate
families, so `SBFont` addresses every weight by its own PostScript name.

The same folder carries Termstead's own license (GPL-3.0-or-later, a copy of
`LICENSE`) and the MIT notices of SwiftTerm and Sparkle: GPLv3 wants its text
with every copy of the app, and MIT its notice. Refresh `MIT-Sparkle.txt` when
Sparkle is updated.

## Known pitfalls

These have each cost real time. They are not hypothetical.

- **A SwiftUI row whose height equals the ignored top safe-area inset does not
  paint.** A 28pt first row under `.ignoresSafeArea(.all, edges: .top)` reserves
  its layout and draws nothing — background included. 29 and 30 behave the same;
  40 paints. Every window in the app therefore names itself through a leading
  `NSTitlebarAccessoryViewController` (`WindowConfigurator.titlebarTitle`)
  instead of drawing a bar of its own.
- **SwiftUI backgrounds bleed into the safe area; overlays do not.** The window
  uses `.fullSizeContentView`, so any `.background(...)` at the top of the
  content paints up under the titlebar — which split the strip into the
  sidebar's tone and whatever the right column had on top (the terminal's
  near-black on the first-launch screen). `MainView` therefore `.clipped()`s the
  content row, and the titlebar strip is painted by the root background alone
  (`theme.sidebar`). Keep that clip; don't try to match tones column by column.
- **`.overlay`, not `.background`, for an AppKit interaction layer.** As a
  background the view is hit-tested and returns itself, yet SwiftUI still
  swallows the `mouseDown`. On top, it must hand back the strips SwiftUI still
  owns (`RowInteraction.passthrough`, and right-clicks for `.contextMenu`).
- **A `Button` plus `.onTapGesture(count: 2)` on one view costs 357 ms** before
  the single click fires. Never pair them.
- **`NSApp.appearance` must follow the theme**, not just the window's: sheets and
  popovers are their own `NSWindow`s and otherwise take AppKit's text, selection
  and placeholder colours from macOS. Consequently `ThemeStore` reads the system
  appearance from `AppleInterfaceStyle`, not from `NSApp.effectiveAppearance`.
- **`SessionStore.flattened` must stay pure.** It runs from `body`; writing to
  observed state there invalidates the view drawing it.
- **The top-level drop zone must be a sibling of the rows**, not an ancestor.
- **`.dropDestination` resolves its payload asynchronously.** Read the pasteboard
  synchronously in `performDragOperation` if the drop should land on mouse-up.
- **Windows move by their titlebar only** (`isMovableByWindowBackground` is
  off). While it was on, AppKit claimed drags from any view whose
  `mouseDownCanMoveWindow` is true, which is every plain SwiftUI view. The
  titlebar's name accessory is a `TitlebarDragHostingView` so the window can be
  grabbed by its name too.
- **Screenshotting cancels an interaction in flight.** `screencapture` during an
  `NSDraggingSession` ends the drag, and during `NSMenu` tracking dismisses the
  menu — both look exactly like a regression. Verify by the outcome instead.
- **Capture one window by id** (`CGWindowListCopyWindowInfo` + `screencapture -l`).
  A region capture pulls in whatever else is on screen. Note that `sips
  --cropOffset` is measured from the centre, not the top-left, so it is a poor
  tool for cropping a screenshot.
- **A sheet cannot be moved.** AppKit pins it to the parent's top edge for as
  long as it is up, and nothing in `presentationDetents`-land changes that on
  macOS. The forms are therefore plain titled windows added with
  `addChildWindow`, and they close by clearing `AppState.route` — SwiftUI's
  `dismiss` does nothing in a window it did not present, which is why the forms
  take a `\.closeForm` action from the environment instead.
- **`NSApp.runModal` must not start inside a main-queue block.** It is a nested
  run loop, and the serial main queue stays busy with the block that called it
  — terminal output and SwiftUI updates both come through that queue and would
  stall for as long as the form is open. `FormWindowHost` starts it from
  `RunLoop.main.perform` instead. Ending it: `stopModal` only takes effect after
  the current event, so a close that comes from a state change posts a wake-up
  event, and the form closes itself rather than waiting for SwiftUI to apply the
  cleared route.
- **An NSWindow created in Swift must set `isReleasedWhenClosed = false`.**
  Otherwise closing releases it on top of ARC, and the close animation later
  touches freed memory — in the tests this crashed the host mid-suite and
  looked like a bug in the modal code.
- **Sidebar selection: one anchor, a set of rows.** `SessionStore.selection` is
  the anchor the commands act on; `selectedItems` is every highlighted tree row.
  A pinned session is also in the tree, so the Pinned strip is kept out of the
  set — selecting by id alone highlighted both rows once.
- **A plain press on a multi-selection must wait for mouse-up.** Clicks act on
  mouse-down (the 357 ms lesson), but narrowing the selection on the press made
  it impossible to drag several rows. `RowInteraction.isInMultiSelection` defers
  that one case.
- **Swapping an `NSHostingController`'s `rootView` leaves the window with no
  first responder.** The new fields draw normally, including the focus ring the
  form paints itself, and every keystroke is dropped until one is clicked;
  `makeFirstResponder(contentView.nextValidKeyView)` does not recover it. A
  window created with its content in place picks the first field by itself, so
  `FormWindowHost` opens a fresh window per form and carries the old one's
  top-left corner over.
- **SwiftTerm 1.11 may never report that the process exited.** When the pty
  hits end-of-file before its exit monitor fires, `LocalProcess` cancels the
  monitor and the `processTerminated` call is commented out. `Connection`
  watches the pid with its own `DispatchSource`. SwiftTerm's exit code is also
  the raw `waitpid` status: decode it (`Connection.exitCode(fromWaitStatus:)`).
- **SwiftTerm's delegate protocols are not actor-isolated** (the package is
  Swift 5 mode) but call back on the main queue. The relay copies what it needs
  into locals and uses `MainActor.assumeIsolated`; capturing `self` there is a
  Swift 6 error.
- **SwiftTerm 1.11's `mouseUp` is `public`, not `open`**, and its `selection`
  is internal. Copy-on-select hooks `selectionChanged(source:)`, reads
  `selectionActive`/`getSelection()`, and polls the mouse button to copy once
  on release.
- **Clicking a sidebar row takes the keyboard** (`RowInteraction.onDeleteKey`
  makes the layer a first responder), so ⌫ can delete the selection. Rows
  without it — the root drop zone — never take focus.
- **SwiftTerm's `Attribute` has no public initialiser.** Keyword highlighting
  (`HighlightPainter`) gets coloured attributes by feeding an SGR sequence to a
  private scratch `Terminal` and reading the cell back; it recolours only cells
  whose foreground is `.defaultColor`, and never on the alternate screen.
- **SwiftTerm sets the I-beam over its whole view**, scroll bar included, and
  both `resetCursorRects` and `cursorUpdate` are closed to overriding.
  `TerminalPane` lays `ScrollerShield` over the scroll bar for the arrow and
  forwards the mouse to it.
- **The tests share the app's UserDefaults domain.** They are hosted in the
  app, bundle id and all, so a test run leaves window frames and the like in
  the real `com.pavelkhorenyan.Termstead` preferences. To see what a new user
  sees, quit the app and clear that domain after the tests, not before. A test
  that needs clean defaults takes a `UserDefaults(suiteName:)` of its own (see
  `ThemeStore(defaults:)`).
- **Waiting in a main-actor test must suspend, not spin.** SwiftTerm delivers
  output with `DispatchQueue.main`; a `RunLoop.run` inside the test's own job
  never lets those blocks run, and the screen stays empty.
- **ssh truncates names in prompts**: `%.100s` for a key file, `%.30s` for a
  user. `AskpassMatcher` matches a name at that length by prefix, and only when
  exactly one candidate fits. Never send a secret on a guess — a password given
  to the wrong host has left.
- **A Unix socket path must fit in 104 bytes.** The connection's work directory
  is `$TMPDIR/sb-xxxxxxxx` for that reason; a UUID-named one was close to the
  limit.
- **An ad-hoc build cannot run under the hardened runtime.** Sparkle.framework
  is a separate library, and library validation refuses to load it into an
  ad-hoc app: "mapping process and mapped file have different Team IDs", and
  the app dies at launch. So `Config/Signing.xcconfig` turns the hardened
  runtime off for ad-hoc Release builds, and a real identity in the gitignored
  `Config/Signing.local.xcconfig` turns it back on. Pavel's builds are signed
  with his Developer ID there.
- **Keychain access is tied to the binary.** An ad-hoc build gets a new
  signature on every rebuild, so the first read of an existing item shows an
  access dialog. Builds signed with a stable identity (the local xcconfig
  above) keep their access. That
  is why the helper asks the app instead of reading the Keychain itself, and why
  it waits up to 60 s for an answer. `KeychainStore.contains` reads attributes
  only, which never prompts.
- **With `SSH_ASKPASS_REQUIRE=force`, every question goes to the helper** —
  including host-key yes/no. The helper hides input unless the prompt is a
  plain confirmation, and askpass is only switched on when the chain has a
  stored secret.
- **From macOS 15, SwiftUI owns the pointer inside its hosting view.** An
  AppKit view's `cursorUpdate`/`NSCursor.set()` is overwritten with the arrow
  on the next mouse move. Declare cursors with `.pointerStyle(...)` (see
  `resizeCursor()`), keeping the AppKit path only for macOS 14.
- **Don't use `frameAutosaveName` on SwiftUI's windows.** SwiftUI names them
  itself (`NSWindow Frame appearance`, and type-name keys for a `WindowGroup`)
  and puts its name back, so anything keyed on "already set" runs on every
  update — the saved frame was re-applied each time a theme was picked.
  `FrameKeeper` applies a saved frame once per window and saves on move/resize.
- **Scroll bars follow the input device, not the design.** With a mouse
  attached macOS gives every scroll view the legacy 15pt scroller, and the
  overlay one swells on hover. Put `ThinScroller` inside a SwiftUI
  `ScrollView`: it installs `SlimScroller` (a fixed 5pt knob, no track) and
  re-applies it when the system preference changes. The sidebar and the Files list pass
  `alwaysVisible: true` (the legacy style with `autohidesScrollers`): Pavel
  wants the bar in sight whenever the list overflows.
  The two styles differ in where the knob goes: the overlay style draws it
  over the content, the legacy (always-visible) one narrows the visible area
  by `SlimScroller.lane` while the bar shows. To keep a form's margins even,
  give the content a fixed width held to the leading edge — a ScrollView
  centres narrower content — make the scroll view one lane wider, and take
  the lane out of the trailing margin (see `SessionSheet`).
- **AppKit window restoration is off** (`ApplePersistenceIgnoreState`,
  registered in `TermsteadApp.init`). A saved state with no windows in it
  brought the app up windowless — the process running, idle, and no window to
  bring forward. Frames are `FrameKeeper`'s job.
- **The sidebar is not CPU-bound.** When something feels slow and the profiler
  shows nothing, look for a gesture or a timer, not a hot loop. Measure with
  `proc_pid_rusage`; `xctrace` totals disagreed with it by ~40× here.
- **The app icon must fill its whole canvas.** macOS 26 rounds an app icon
  itself; one drawn on Apple's older grid (a body inset in transparent margins)
  lands on a light plate in the Dock. `AppIcon.appiconset` is full bleed, square.
- **"no debug symbols in executable" after an `Info.plist` change is Xcode's,
  not ours.** The dSYM carries a copy of `Info.plist`, so an incremental
  Release build regenerates it from the executable it did not relink — one
  that has already lost its debug information — and warns per architecture.
  A clean build (and so `release.sh`'s archive) has no warning; check there.
- **A menu shortcut matches by character, Shift included.** "Bigger" is
  ⌘+, and ⌘= alone — the key people press — matched nothing, since `+` takes
  Shift on most layouts. `AppDelegate.plusForEquals` rewrites ⌘= as ⌘+ in a
  local event monitor, so the menu item still decides whether it is enabled.
- **A find match is a selection.** SwiftTerm shows it through the selection
  service, so `selectionChanged` fires with no mouse button down and
  copy-on-select would copy every match. `SSHTerminalView.find` sets
  `isFinding` around the call; search through it, not `findNext` directly.
  The match has a style of its own (`Theme.findMatch` / `onFindMatch`, a
  solid fill with its own text color, through the vendored
  `selectedTextForegroundColor` patch); the view swaps it for the
  translucent selection style when a selection is made any other way.
- **SwiftTerm's `font` setter clears the selection**, even for the same
  font. `TerminalStyle` sets it only when it changed; otherwise every theme
  change dropped a find match or the user's selection.
- **An imported session's host is its `~/.ssh/config` alias**, not the address.
  The generated config reaches the user's block through `Include`, so the
  alias must stay the `Host` name; `user`/`port` are copied from `ssh -G`
  because Termstead's own block comes first and would override them. An empty
  key path means "let ssh choose".
- **The Files tab rides the terminal's connection.** The terminal's ssh is
  started with `ControlMaster=auto` on the command line — not in the config,
  which `sftp` reads too, and `-o` is not passed on to `ProxyJump` hops — and
  `sftp` joins with `ControlMaster=no`, `BatchMode=yes`, `RemoteCommand=none`,
  `RequestTTY=no`. A config with a `RemoteCommand` otherwise makes ssh refuse
  the sftp subsystem. The control socket's temporary name adds 17 characters,
  which must still fit the 104-byte socket path limit.
- **`sftp` quoting**: inside double quotes it takes `*`, `?` and `[`
  literally — escaping them left a real backslash in the name. Only `\` and
  `"` are escaped (`SFTPClient.quote`). The protocol cannot remove a folder
  that is not empty; that one is `rm -rf` over the same connection.
- **A stored secret may be needed once per hop.** The same passphrase-protected
  key on a bastion and a target is asked for by two ssh processes;
  `AskpassMatcher.uses(of:)` sets how many answers each secret gets before the
  terminal takes over.
- **sftp's output depends on the locale.** Without a UTF-8 `LC_CTYPE` it
  prints every non-ASCII byte in a name as `\ooo` — and an app launched from
  Finder has no `LANG`. `SFTPClient` sets `LC_CTYPE=UTF-8`. Also, a failed
  `ls` inside a batch does not fail the batch: `list` reads stderr for it.
- **"Follow the terminal" asks the server, not the screen.** Every channel
  over the connection master is a child of one `sshd` session process, so
  `SFTPClient.terminalDirectory` climbs from its own shell to that process and
  reads `/proc/<pid>/cwd` of the child with a terminal. Prompts vary and a
  shell reports nothing by itself (OSC 7) unless set up to. Linux only.
- **SwiftTerm 1.11 leaked a read op per partial delivery** (fixed in the
  vendored copy): DispatchIO calls the read handler several times per op, and
  re-arming on each call multiplied the read chains. One tab after 300k lines
  held 37k pending ops and 468 MB; with the patch, 126 MB. `ReadChainTests`
  checks that at most one read is outstanding.
- **A color id is a palette id, `"none"` or `#RRGGBB`.** Groups and sessions
  store one in `colorID`; `GroupColor.swatch(for:)` resolves all three, so
  code that resolves ids handles custom colors without knowing. A colored
  group decides for every session in it; a session's own id shows only where
  no group colors it (`GroupColor.sessionColorID`, used by the flattening and
  `sessionIndex`) — Pavel's rule, and the session form hides its swatches
  there. Custom colors derive their per-theme
  variants in `GroupColor.readable` and are cached. They are picked in
  `ColorPickerWindow`, a Photoshop-style dialog, not the system color panel
  (a screen corner, crayons, web-safe lists). It opens over a form that is
  already app-modal, so it runs a **nested** modal session started from the
  modal-panel run-loop mode — `AppModal.begin` waits for the default mode,
  which never comes while the form's session runs — and its window title is
  the system's own (a SwiftUI title row sits under the titlebar or, at 28pt,
  does not paint).
