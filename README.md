# Flick

**Use your iPhone as a trackpad and keyboard for your Mac.**

Flick turns your iPhone's screen into a full-size trackpad. When you click into a text field on the Mac, the iPhone keyboard pops up on its own, with autocorrect, QuickType, swipe-typing and dictation. When focus leaves the field, the keyboard goes away.

It's two apps:

| | |
|---|---|
| **Flick** (iPhone) | The trackpad and keyboard. |
| **Flick for Mac** (menu bar) | Receives input from the phone, moves the pointer and types, and watches which UI element has focus so the phone knows when to show the keyboard. |

They connect over Wi-Fi, over Apple's peer-to-peer Wi-Fi when there's no shared network, and over Bluetooth LE at the same time. Whichever copy of each movement arrives first wins, so typical pointer latency is about 2 ms over the network.

> **Status:** pre-release. Until the App Store and Mac downloads are available, [build it from source](#build-from-source).

## Gestures

| iPhone | Mac |
|---|---|
| 1 finger move | pointer (with acceleration) |
| tap | left click (tap twice for a double-click) |
| 2-finger tap | right click |
| 3-finger tap | middle click |
| 2-finger move | scroll, with trackpad momentum |
| press & hold (haptic bump), then move | drag; over text, selects by word |
| swipe up and down along the side edge | one-handed scrolling |
| swipe up from the bottom edge | Mission Control |
| slide along the bottom edge | switch Spaces, following your finger |
| 3 fingers left/right, up/down (phone flat on a table) | Spaces, Mission Control, App windows |
| 4–5 finger spread | Show Desktop |
| ⌨︎ button | open the keyboard manually (e.g. for shortcuts) |

The bar above the keyboard has esc, tab, one-shot ⌘ ⌥ ⌃ ⇧ (tap ⌘, then `c` = ⌘C), arrow keys, ⌦ and your pinned shortcuts. The trackpad stays usable above the keyboard while you type.

## Requirements

- iPhone with iOS 17 or later
- Mac with macOS 14 or later
- Both on the same Wi-Fi, or close enough for peer-to-peer Wi-Fi or Bluetooth

## Getting started

1. Open **Flick for Mac**. Approve both prompts:
   - **Local Network**: lets the phone find the Mac.
   - **Accessibility**: System Settings › Privacy & Security › Accessibility → enable Flick. This is what lets it move the pointer, type, and detect text fields.
2. Click the swoosh in the menu bar to see the 6-digit pairing PIN.
3. Open **Flick** on the iPhone, tap your Mac, and enter the PIN.

After the first connection, the phone is paired with that Mac and reconnects without the PIN. To pair a different phone, choose **Unpair** in the Mac's menu.

## Privacy

- Flick has no accounts, servers, analytics or tracking. Everything stays between your iPhone and your Mac.
- To show a preview of what you're typing, the Mac sends the phone the text around the cursor in the focused field. It never reads or sends the contents of password fields.
- The Mac app keeps a local performance log (timings and counts, never typed text) at `~/Library/Logs/Flick/perf.log`, capped at about 10 MB.

## Security

All traffic between the phone and the Mac is encrypted and authenticated. The PIN is used once, to pair; after that the two devices use a random 256-bit key stored in each device's Keychain, and the Mac stops accepting the PIN. Wrong PIN guesses are rate-limited. See [SECURITY.md](SECURITY.md) for details and how to report a vulnerability.

## Build from source

You need Xcode and an Apple ID. A free Apple ID is enough to run it on your own devices.

1. Clone the repo and open `Flick.xcodeproj`.
2. For both the **Flick** and **FlickMac** targets, open *Signing & Capabilities*, choose your own team, and change the bundle identifier to one you own (e.g. `com.yourname.flick` and `com.yourname.flick.mac`).
3. **Mac:** select the **FlickMac** scheme and Run.
4. **iPhone:** turn on Developer Mode on the phone (Settings › Privacy & Security), select the **Flick** scheme and your phone, and Run. The first time, trust the developer profile on the phone: Settings › General › VPN & Device Management.

With a free Apple ID, apps installed on the phone this way stop launching after 7 days; Run again from Xcode to refresh. The Mac's Accessibility permission is tied to the app's code signature, so keep signing with the same team or you'll need to grant it again.

## How it works

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the transport design, text-field detection, how typing is replayed, latency measurements and a source map.

## Known limitations

- Some custom-drawn text views don't expose accessibility roles (some games and terminal emulators). Use the ⌨︎ button there.
- Pinch-to-zoom and "lift and continue" dragging aren't implemented yet.
- The iPhone can't act as a plain Bluetooth mouse or keyboard (iOS doesn't allow it), so the Mac app is always required.

## Credits

Instant Space switching (`Mac/SpaceSwitcher.swift`) is ported from [InstantSpaceSwitcher](https://github.com/jurplel/InstantSpaceSwitcher) by jurplel, used under the MIT License. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## License

MIT. See [LICENSE](LICENSE).
