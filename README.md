# WatchPointer

<img src="docs/icon.png" width="96" align="right" alt="">

Use your Apple Watch as a pointer for your Mac. Point it at the screen to move the cursor, tap to click, hold to drag.

No Wi-Fi, no servers: the watch talks straight to the Mac over Bluetooth.

<p align="center">
  <img src="docs/demo.webp" width="320" alt="Holding an Apple Watch like a remote and pointing it at a MacBook to move the cursor">
</p>

## What it does

- **Point** like a laser pointer: the cursor goes where the pointing edge of the watch points: the Digital Crown side (3 o'clock) at first. The edge button next to Pause switches it, each tap going 12 → 3 → 6 → 9 o'clock. Works across all your displays.
- **Tap** the pad to click, **hold** to drag, **right-click** button, **Digital Crown** to scroll.
- **Double Tap** (tap your index finger and thumb together twice) clicks too, without touching the watch. Needs an Apple Watch with Double Tap (Series 9, Ultra 2 or newer), turned on in the watch's **Settings › Gestures**. The pointer holds still for a moment after that click, because the gesture itself moves your wrist.
- **Speed**, **Steady** and **Scroll** settings on the watch (button at the top left, − and + for each): Speed is how far you have to turn to cross the screen, Steady ignores more of a shaking hand but follows a little slower, and Scroll is how fast the Digital Crown scrolls.
- **Center** re-aims the middle of the screen; **Pause** frees the cursor for your trackpad.
- **Pair** with a Mac once; the watch only connects to that Mac until you unpair it.
- **Notch panel** on the Mac: connection state, the watch's name and model, battery, live aim, and a pin to keep it open.
- **Sky Shot**, a small light-gun style game to try it on.

## Requirements

- Mac with macOS 14 or later and Bluetooth
- Apple Watch with watchOS 11 or later
- Xcode 16 or later (to install the watch app)

## Run it

### 1. Mac receiver

```bash
cd Mac
swift run WatchPointer
```

The first time, macOS asks for **Bluetooth** access and for **Accessibility** access (System Settings › Privacy & Security › Accessibility) for your terminal app. Accessibility is what lets it move the cursor. Allow both, then run it again.

It shows up in the notch (or the middle of the menu bar on Macs without one).

### 2. Watch app

1. Open `Watch/WatchPointer.xcodeproj` in Xcode.
2. In **Signing & Capabilities**, pick your team. If Xcode complains about the bundle identifier, change it to something of your own.
3. Choose your Apple Watch as the run destination and press **⌘R**.
4. Open WatchPointer on the watch and tap **Pair** next to your Mac.
5. On the Mac, click **Allow** in the dialog that asks whether the watch may control your cursor.

### 3. Point

Point your arm at the screen so the pointing edge faces it. At first that is the edge with the Digital Crown (3 o'clock); on the left wrist it is the side toward your fingers. The edge button next to Pause changes it (12, 3, 6, 9 o'clock) and recentres. Aim at the middle of the screen and tap **Center** to line it up.

## Settings

All on the Mac, no reinstall needed:

```bash
swift run WatchPointer 1.2               # speed: higher = less turn to reach the edges
swift run WatchPointer steady=0.6        # steadier when holding still (default 0.8)
swift run WatchPointer quick=0.02        # less lag on fast moves (default 0.01)
```

The Speed and Steady settings on the watch multiply `speed` and `steady`/`quick` above (1× = exactly what you started the receiver with), and are remembered on the watch. They reach the Mac as soon as you change them; the receiver prints a `settings:` line when they arrive. Restart the receiver after updating it: an older one ignores them.

## Sky Shot

Open `Game/index.html` in a browser, press **F** for full screen, and tap the watch to start. Paper planes fly across a sky that turns from morning to sunset as the round runs out. Bullseyes count double, gold planes triple.

## Tips for using it in your hand

On the iPhone's Watch app, turn off **Passcode › Wrist Detection**, or the watch locks as soon as it's off your wrist. On the watch, set **Display & Brightness › Wake Duration** to 70 seconds and **General › Return to Clock › WatchPointer** to one hour.

## How it works

- **Watch** (`Watch/`): reads gravity and the gyroscope 100 times a second. Up/down comes from gravity, so it never drifts; left/right adds up turns around the vertical. Each sample is sent with the watch's timestamp.
- **Mac** (`Mac/`): projects the aim onto the screen like a laser hitting a wall, smooths it with a [1€ filter](https://gery.casiez.net/1euro/) using the watch's timestamps, and moves the cursor 240 times a second on its own thread. Clicks land where you were pointing the moment your thumb touched the watch, so the tap's jolt doesn't move them.
- **Bluetooth**: the Mac advertises a service; the watch connects and writes small packets (aim, click, drag, scroll, pause, info). The protocol is documented at the top of `Mac/Sources/WatchPointer/Receiver.swift`.

## Security note

Pairing is chosen on the watch, but the Mac decides who may move its cursor. The first time a device connects, the Mac shows **“Allow … to control your cursor?”**. Until you click **Allow**, nothing the device sends is acted on: no movement, clicks or scrolling. **Don't Allow** is the default button.

- Your answer is kept only while the receiver is running. Quit and start it again, and it asks again.
- The watch shows **Approve on your Mac** while it waits, and **Declined on your Mac** if you refuse. To ask again, unpair on the watch and pair again.
- The name in the dialog is reported by the device itself, so check the device ID too. Only click Allow when you have just opened WatchPointer on your own watch.
- This is a confirmation, not strong authentication: the app doesn't require an encrypted or authenticated Bluetooth link, and it recognises a device by the ID Bluetooth gives it. Quit the receiver when you're not using it.

## License

MIT, see [LICENSE](LICENSE).
