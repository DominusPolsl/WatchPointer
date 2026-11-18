# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

WatchPointer turns an Apple Watch into an air-pointer for a Mac, over Bluetooth LE (no network). Three independent pieces live in one repo:

- `Mac/` — Swift package (macOS 14+), a CLI-launched accessory app that advertises a BLE service, receives packets, and moves the cursor. Also draws a "notch panel" status UI.
- `Watch/` — Xcode project (watchOS 11+, watch-only app) that reads motion data and writes packets to the Mac.
- `Game/index.html` — "Sky Shot", a single-file canvas game driven only by ordinary mouse events (so it works with WatchPointer or a trackpad). Not connected to the Swift code.

There are no tests, linter or CI configured.

## Commands

```bash
# Mac receiver (from Mac/). Needs Bluetooth + Accessibility permission for the launching terminal app.
cd Mac && swift run WatchPointer
swift build                                  # build only
swift run WatchPointer 1.2 steady=0.6 quick=0.02   # tuning args: speed (bare number), steady=, quick=

# Watch app: no CLI workflow. Open Watch/WatchPointer.xcodeproj in Xcode, pick a signing team,
# choose your Apple Watch as the run destination, ⌘R.
```

- `Mac/Package.swift` embeds `Sources/WatchPointer/Info.plist` into the binary via an `-sectcreate __TEXT __info_plist` linker flag (`unsafeFlags`). That is what gives the bare CLI binary a Bluetooth usage string; the plist is excluded from normal resources. Run `swift` from `Mac/` because the linker path is relative (`Sources/WatchPointer/Info.plist`).
- The Watch project uses a file-system-synchronized group, so new `.swift` files dropped into `Watch/WatchPointer/` are picked up without editing `project.pbxproj`. Its `DEVELOPMENT_TEAM`/bundle id (`io.loopbreak.watchpointer`) are the author's; the README expects users to change them.
- Sky Shot: just open `Game/index.html` in a browser.

## Architecture

### The BLE protocol is duplicated, not shared

The Mac and Watch targets share no code. The following are **copy-pasted in both** `Mac/Sources/WatchPointer/Receiver.swift` and `Watch/WatchPointer/WatchPointerApp.swift` and must be changed in both places together:

- The three characteristic/service UUIDs (`serviceUUID`, `inputUUID`, `outputUUID`).
- `enum Kind` (aim, leftClick, rightClick, scroll, center, pause, info, drag, settings) and the packet layout. Two packet meanings beyond the fixed layout: `.leftClick` with `b = 1` is a Double Tap click (the Mac holds the pointer still for `gestureHold`, then eases back), and `.settings` carries `a` = Speed ×100, `b` = Steady ×100 (multipliers on the Mac's command-line values; the Mac ignores them until the watch is approved, so the watch resends them on approval).

Packet format: `[kind: UInt8, a: Int16 LE, b: Int16 LE]` (5 bytes), optionally followed by a `UInt16 LE` watch-clock timestamp in ms (7 bytes total) for `.aim`, clicks and drags. `.info` is the exception: `[kind, JSON]` decoded into `WatchInfo`. The canonical protocol description is the doc comment above `Kind` in `Receiver.swift`. The receiver tolerates older watch builds that omit timestamps (falls back to arrival time), so keep new fields optional/length-checked.

Roles: the **Mac is the BLE peripheral** (advertises, hosts the characteristics); the **watch is the central** (scans, connects, writes). The watch subscribes to `outputUUID` solely so the Mac gets a `didUnsubscribeFrom` callback when the link drops — nothing is ever sent on it. Pairing is purely watch-side: the watch stores the chosen Mac's peripheral UUID in `UserDefaults` and only connects to it until "Forget". The Mac does not authenticate the watch cryptographically, but it asks its owner before a new device may steer the cursor: `Receiver.access(for:firstPacket:)` ignores every packet from a `CBCentral.identifier` that isn't in the in-memory `allowed` set (nothing is persisted, so it asks again after each launch) and `ConsentPrompt` (`Consent.swift`) shows the alert. Writes that expect an answer get an ATT error back — `.insufficientAuthorization` = waiting for approval, `.writeNotPermitted` = declined — which `Pointer.peripheral(_:didWriteValueFor:error:)` on the watch turns into `Access` (`.waiting`/`.declined`). Those two error codes are part of the protocol: keep both sides in step. The name in the alert is self-reported by the device (spoofable), so the alert also shows the device ID.

### Watch → aim (`WatchPointerApp.swift`, class `Pointer`)

`CMMotionManager` at 100 Hz. Elevation (how far the pointing edge tips above horizontal: `asin` of `up.y`, `up.x`, `-up.y` or `-up.x` for the 12, 3, 6 or 9 o'clock edge, see `Pointer.edge` and `elevationOf`) comes from gravity (absolute, no drift); heading is the integral of rotation rate about the vertical axis (relative, zeroed by "Center"/`recenter()`). Each aim sample carries the watch's own timestamp, because BLE delivers samples in bursts and arrival times are useless for smoothing. Aim and scroll use `.withoutResponse` writes gated on `canSendWriteWithoutResponse` (dropping a sample is fine); clicks, drags, pause and info use `.withResponse`. `ContentView.swift` is the UI (pad = tap click / hold-to-drag, three buttons, Digital Crown scroll). Double Tap (the watch gesture) is an invisible, hit-test-disabled `Button` with `.handGestureShortcut(.primaryAction)` overlaid on the pad; it sends a left click timed `doubleTapLead` seconds in the past (a tuning guess, only checkable on a real watch). The Digital Crown only scrolls, scaled by `Pointer.scrollSpeed` (a watch-only setting; nothing is sent to the Mac) and never faster than `scrollCeiling` px/s times that (`Pointer.scroll(crown:)`): the Crown yields many units per turn and the exact number is unknown, so a ceiling bounds the speed whatever it is. The Mac builds the scroll event with `units: .pixel`, which apps read as precise pixel deltas (`scrollingDeltaY` = pixels), so it adds no amplification of its own. The edge button beside Pause calls `Pointer.cycleEdge()` (12 → 3 → 6 → 9, then recentres); the toolbar button opens `SettingsSheet` (Speed/Steady/Scroll steppers, Reset, Unpair). Click/drag/right-click packets carry the touch-down time (`systemUptime`, the same clock as the motion samples) so the Mac can rewind; right-click is sent with a hardcoded `- 0.12` s estimate because SwiftUI buttons only fire on release.

### Mac pipeline (`Receiver.swift`)

All cursor work runs on a dedicated `.userInteractive` `DispatchQueue` (`WatchPointer.pointer`) that is also the CoreBluetooth delegate queue, so UI drawing on the main thread can never delay it. State in `Receiver` is only touched on that queue; anything the notch displays is pushed to `Live` via the `ui { }` helper (hops to main). Flow:

1. `aim()` projects degrees → screen coords like a laser on a flat wall (`reachDegrees = 25 / speed`), runs per-axis `OneEuroFilter`s using the **watch-clock** `dt`, and stores a `target`.
2. A 240 Hz timer (`startFrameLoop`/`tick`) glides `shown` toward `target` and posts `CGEvent` mouse moves; `Displays.clamp` maps the point onto the multi-display layout (pins to nearest display when aiming past an edge). If no sample for 0.3 s the cursor is left alone (so the trackpad works), a held drag is released, and after 1.5 s the phase flips to `.idle`.
3. Clicks/drags rewind to where the cursor **was at touch-down**: `when(_:)` converts the packet's watch timestamp to Mac time using `clockOffset` (Mac-minus-watch offset taken from the quickest-arriving sample), and `pressPoint(at:)` looks that moment up in a ~1 s `history` ring. This undoes the jolt from tapping the watch. Missing timestamps fall back to `fallbackRewind`.

Settings (`speed`, `steady=`, `quick=`) are parsed from `CommandLine.arguments` as top-level globals in `Receiver.swift`. The watch's Speed/Steady (`Pointer.speed`/`.steady`, persisted in `UserDefaults`, changed with the − / + steppers in `SettingsSheet`, over the fixed `speedLevels`/`steadyLevels`/`scrollLevels` in `ContentView.swift`) arrive as `.settings` and are applied in `Receiver.apply(speed:steady:)`: Speed scales `reach` (= `reachDegrees / speed`), Steady divides `minCutoff` of the two `OneEuroFilter`s by it and `beta` by its square (beta opens the filter for fast movement and a shaky hand is fast movement too, so dividing it only by `steady` left most tremor through). A receiver started before this existed ignores `.settings` silently, so check its start time when Speed/Steady seem to do nothing.

### Mac UI (`Live.swift`, `Notch.swift`, `WatchInfo.swift`, `main.swift`)

`main.swift` requests Accessibility trust, sets `.accessory` activation policy, and wires `Live` (the `ObservableObject` model written by `Receiver`) → `Receiver` → `NotchController`. `Notch.swift` builds a borderless `NSPanel` over the top-center of the notched screen (or a small island under the menu bar when there's no notch); it is click-through (`ignoresMouseEvents`) except while the cursor hovers it, which a 20 Hz timer checks. `WatchInfo.swift` maps hardware ids (`Watch7,5`…) to marketing names via a hand-maintained table — add new watch models there.
