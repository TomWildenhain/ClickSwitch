# ClickSwitch

Tired of MacOS bringing every window to the foreground when you switch applications? As a Windows user, I miss the ctrl+click taskbar combination which cycles through application windows in the order they were most recently used.

ClickSwitch uses the accessibility API to bring this functionality to MacOS. Hold down the command key while clicking a dock icon to enjoy single-window-activation bliss. The tool can be configured to use alternative modifier keys (or none at all) and launch at startup.

## AI Disclosure

The majority of this project was generated with AI (Cursor + Claude Opus 5). See PROMPTS.txt for the prompts used in this project. All parts of the README below this point were AI-generated. 

_AI should not modify text above this point._

## Description

Windows-style Dock window cycling for macOS. **⌘-click an app's Dock icon** to jump to its next
window, ordered by how recently each window was in the foreground. Keep clicking to keep walking
through them.

It runs as a menu bar item with no Dock icon or main window.

## Install

```sh
./build.sh --install
```

That compiles the app, assembles `ClickSwitch.app`, ad-hoc signs it, copies it to `/Applications`
and launches it. Drop `--install` to just build into `./build`.

On first launch macOS will ask for **Accessibility** permission. Grant it in
System Settings → Privacy & Security → Accessibility. The menu bar icon switches from a
crossed-out stack to a plain stack once everything is live; no relaunch needed.

## How it behaves

- ⌘-click an app that is **not** frontmost → its most recent window comes forward. Only that
  window: the app's other windows stay exactly where they are in the stack, rather than all
  surfacing together the way ordinary app switching works on macOS.
- ⌘-click an app that **is** frontmost → advances to the next window.
- Each further ⌘-click keeps advancing and wraps around at the end.
- Doing anything else in between (switching apps, clicking another window) starts a fresh cycle
  from the current most-recently-used order.

That last rule is what stops it from ping-ponging between the two most recent windows: while you
are actively cycling, the app walks one frozen snapshot of the window order instead of
re-sorting after every raise.

Apps with one window, or that aren't running, behave like a normal Dock click. So does a running
app with no windows left open: it gets a fresh window rather than just coming forward empty.

## Menu bar options

- **Cycle Modifier** — ⌘ by default; ⌥, ⌃, ⇧, ⌘⌥, ⌘⇧ and ⌘⌃ are also available. Matching is
  exact, so ⌘⇧-click won't fire while plain ⌘ is selected.
  - **No Modifier** — makes an ordinary left click cycle, so the Dock behaves like the Windows
    taskbar with no keys held. Because a plain press on the Dock is also how you rearrange it,
    nothing happens until the mouse comes back up: move more than a few pixels and the gesture
    is handed back to the Dock as a normal icon drag.
  - **Multiple** — at the top of the same submenu. Off by default, where picking a modifier
    replaces the current one. Switch it on and the modifiers become checkboxes: any one of the
    ticked modifiers triggers cycling. The last remaining tick can't be cleared, since an empty
    selection would leave nothing to trigger on. Switching Multiple back off keeps the first
    ticked modifier in menu order and clears the rest.
- **Include Minimized Windows** — on by default; minimized windows are restored as you reach them.
- **Launch at Login**
- **Quit**

## What it overrides

⌘-click on a Dock icon normally means "reveal in Finder", and ClickSwitch takes that over for
running applications. Everything else about the Dock is untouched: plain clicks, right-clicks,
non-app tiles, the Trash and minimized-window tiles all pass straight through. Pick a different
modifier from the menu if you want reveal-in-Finder back.

## How it works

- A `CGEventTap` watches left mouse down, up and dragged. When the held modifiers exactly match a
  configured trigger, the click point is hit-tested against the Dock's own accessibility tree to
  find which application tile it landed on. Only then is the click swallowed, and the cycling
  itself is dispatched off the tap so a slow app can never get the tap disabled for timing out.
- Modifier triggers fire on mouse down. The **No Modifier** trigger cannot, because a plain press
  is ambiguous until you see what follows, so the mouse down is swallowed — the Dock never begins
  tracking — and the outcome is decided later: cycle on mouse up, or, if the pointer travels past
  the drag threshold, re-post the swallowed mouse down so the Dock can run its own drag. The
  replay is tagged in `eventSourceUserData` so the tap ignores its own event.
- Because a plain trigger means the tap sees every left click on the machine, the hit test is
  fronted by a screen-geometry check that rejects any point far from a display edge before the
  Accessibility API is touched.
- `WindowTracker` keeps a per-process most-recently-foregrounded list, fed by `AXObserver`
  notifications (application activated, focused/main window changed, window created) plus
  `NSWorkspace` app-activation notices. Windows it has never seen focused fall back to the window
  server's front-to-back order.
- `WindowActivation` does the raising. macOS activates *applications*, not windows, so anything
  built on `NSRunningApplication.activate` or `AXFrontmost` drags the app's whole window group
  above the other apps'. To surface a single window it instead uses SkyLight's per-window
  activation SPI — the same path the window server takes when you click directly on one
  background window — followed by a synthetic event record that makes the window key. If those
  private symbols ever stop resolving it falls back to plain app activation, which works but
  brings every window forward with it.

## Rebuilding

Ad-hoc code signatures change on every build, and macOS keys Accessibility permission to the
signature. After a rebuild you may need to remove ClickSwitch from the Accessibility list with
the `−` button and re-add it. The menu bar icon shows the crossed-out stack whenever permission
is missing.

## Layout

| Path | Purpose |
| --- | --- |
| `Sources/ClickSwitch/DockClickInterceptor.swift` | Event tap; decides what to swallow |
| `Sources/ClickSwitch/DockHitTester.swift` | Point → Dock tile → `NSRunningApplication` |
| `Sources/ClickSwitch/WindowTracker.swift` | Per-app most-recently-used window order |
| `Sources/ClickSwitch/WindowCycler.swift` | Cycling sessions and window selection |
| `Sources/ClickSwitch/WindowActivation.swift` | Raising one window without raising its siblings |
| `Sources/ClickSwitch/AXElement.swift` | Accessibility API conveniences |
| `Sources/ClickSwitch/AppDelegate.swift` | Menu bar item, permissions, preferences UI |

Requires macOS 13 or later. Builds with the Command Line Tools; Xcode is not needed.

## Cutting a release

```sh
./build.sh --release
```

Produces `build/ClickSwitch-<version>.zip`, containing a `ClickSwitch` directory with
`ClickSwitch.app` inside, ready to attach to a GitHub release. The binary is universal, so it
runs on both Apple silicon and Intel. Bump `CFBundleShortVersionString` in `Resources/Info.plist`
to change the version in the filename.

The archive is written with `ditto` rather than `zip`, which is what keeps the code signature
intact through the round trip.

Two things to tell anyone downloading it. The app is only ad-hoc signed, not signed with a
Developer ID or notarized, so Gatekeeper will refuse to open it on first launch — they need to
right-click the app and choose **Open**, or run
`xattr -dr com.apple.quarantine /Applications/ClickSwitch.app`. And it needs Accessibility
permission, as below.
