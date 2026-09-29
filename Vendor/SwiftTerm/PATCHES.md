# Changes to SwiftTerm 1.11.2

Vendored from github.com/migueldeicaza/SwiftTerm at tag `v1.11.2` (MIT, see
`LICENSE`). Termstead stays on 1.11: 1.12 added a Metal renderer whose shaders
need Xcode's separately downloaded Metal Toolchain to build.

Only `Sources/SwiftTerm` is kept (without `Documentation.docc`), and
`Package.swift` declares the library alone.

## LocalProcess: one read at a time

`LocalProcess.childProcessRead` re-armed `io.read` on every call of its
DispatchIO handler. DispatchIO calls that handler several times per read op —
partial deliveries with `done == false`, then a final `done == true` — so each
partial delivery started another read chain. Under fast output the chains
multiplied: after 300k lines one tab held 37k pending `OS_dispatch_operation`s
and serial queues, and ~380 MB of heap pages they pinned (45 MB live).

The next read is now armed only when `done` is true. `readsArmed` and
`readsCompleted` count them for Termstead's tests. Upstream fixed the same bug
in later releases (see the "Two gates on re-arming the next read" comment in
v1.20's `LocalProcess.swift`).

## Warnings

`MacTerminalView.swift`: `case .moveWindowTo(let newX, let newY)` bound values
it never used, a warning that the remote package used to hide. Termstead's
build is kept free of warnings, so the bindings are dropped.

## TerminalView.setNeedsDisplay(rows:)

A public way to redraw a range of screen rows, computed as `updateDisplay`
computes its own region. Termstead's keyword highlighting recolours cells
itself and used to redraw the whole view each time; `cellDimension`, which
the row geometry needs, is internal.

## TerminalView.selectedTextForegroundColor

A selection only ever changed the background of its cells, and their text kept
its own color. Termstead draws a find match as a solid fill, which in a dark
theme sits under light text, so the fill needs a text color of its own. `nil`,
the default, keeps the upstream behaviour; when set, the glyphs of selected
cells (box drawing and block elements included) take it.
