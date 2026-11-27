# How Flick works

## Overview

```
 iPhone                                         Mac (menu bar agent)
 ───────                                        ───────────────────
 raw UITouch (+coalesced 240 Hz samples)
   │  pointer position ─── UDP (WMM "voice") ─────►  CGEvent @ HID tap
   │                   └── Bluetooth LE ──────────►  (first copy wins)
   │  clicks/scroll/keys ─ TLS (ECDHE-PSK) ───────►  CGEvent @ HID tap
   │                   └── Bluetooth LE, sealed ──►  (each input runs once)
   │                                                  │
   ◄──── focus {editable, secure, app} ───────────────┘  AXObserver (focus changed)
 show/hide iOS keyboard                                 + re-check after each click
```

- **No gesture recognizers.** Touches are handled raw in `touchesMoved`, and each sample goes straight onto the wire. Recognizers add recognition delay.
- **Pointer on UDP.** A lost packet never blocks newer ones (no TCP head-of-line blocking). Packets are HMAC-authenticated with a per-session key and sequence-numbered, so stale or replayed packets are dropped. If UDP can't get through, the pointer falls back to TCP automatically (the status bar shows `UDP` or `TCP`).
- **`serviceClass = .interactiveVoice`** puts the pointer packets in Wi-Fi's highest-priority WMM access category.
- **0.5 s ping** shows live RTT and keeps the phone's Wi-Fi radio out of deep power-save, which is the main source of "first movement lags" on Wi-Fi.
- **Mac side:** events are posted from the network queue, never via the main thread. The event source uses `localEventsSuppressionInterval = 0`.
- **Peer-to-peer Wi-Fi.** Network.framework uses AWDL (the radio link AirDrop uses) when `includePeerToPeer = true`, so the phone can reach the Mac even with no shared Wi-Fi network.

## Security

See [SECURITY.md](../SECURITY.md) for the threat model. In short:

- **Pairing.** The Mac shows a 6-digit PIN while no phone is paired. The first phone to connect with it becomes the paired phone and receives a random 256-bit pairing key over that encrypted session. Both sides store the key in the Keychain. From then on the Mac accepts only that key, so the PIN stops working until you choose **Unpair**.
- **Control channel.** TLS 1.2 with `TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256`. The pre-shared key comes from the PIN (first connection) or the pairing key (every later one). The ephemeral ECDH exchange means someone who records the traffic can't brute-force the PIN offline, and past sessions stay private even if a key later leaks.
- **Wrong PINs are rate-limited.** After 5 failed handshakes the Mac stops accepting connections for 30 s, then twice as long after each further 5.
- **Pointer packets** (UDP and Bluetooth) carry a truncated HMAC-SHA256 under a per-session key handed out over TLS. A new key is made for every session.
- **Inputs over Bluetooth** (clicks, keys, text) are sealed with ChaCha20-Poly1305 under the session key and numbered, so replays are dropped.
- **Password fields.** The Mac never reads or sends the text of a secure field (or one whose hints say "password"), and the phone turns off autocorrect and QuickType learning for it.

## Text-field detection

`FocusWatcher` uses the Accessibility API, the same API VoiceOver uses:

- An `AXObserver` on the frontmost app for `kAXFocusedUIElementChangedNotification`, plus a re-check 40/150/400 ms after every injected click, plus a slow 0.4 s poll as a safety net.
- Editable means: role `AXTextField`/`AXTextArea`/`AXComboBox`/`AXSearchField`, or an `AXEditableAncestor` (web `contenteditable`, e.g. Slack's composer), or a settable value with a caret. `AXSecureTextField` is flagged, and the phone then turns off autocorrect and predictions.
- **Electron apps** (Slack, Discord, VS Code, Notion…) hide their accessibility tree by default. The watcher sets `AXManualAccessibility = true` on every app it observes, and `AXEnhancedUserInterface` on Chromium browsers.

## Typing that feels native

The keyboard belongs to an invisible `UITextField`. Instead of forwarding raw keys, the app **diffs** the field against a mirror after every change and replays the edit: move caret → backspace the changed span → type the replacement. That's why **autocorrect, QuickType suggestions, swipe-typing and dictation** all work. Moving the caret with the iOS space-bar trackpad becomes ← → on the Mac. Return clears the buffer.

## Performance

Measured on an iPhone Air and a MacBook (November 2026) with the built-in benchmark and live telemetry. "Extra one-way delay" is phone→Mac delay above the best seen in the same window.

| Pointer path | Median | p90 | p99 |
|---|---|---|---|
| Wi-Fi UDP only | 1.5–4 ms | 37–67 ms | 84–90 ms |
| Bluetooth LE only | 15–18 ms | 27–33 ms | 43–60 ms |
| **Wi-Fi + BLE racing (default)** | **1.8 ms** | **18–19 ms** | **29 ms** |

Findings:

- **AWDL / peer-to-peer Wi-Fi:** no measurable effect on latency.
- **The bottleneck is usually the Mac's Wi-Fi link.** On battery it can drop off the air for up to ~95 ms every ~512 ms, which looks like Wi-Fi power save (5 × 102.4 ms beacons). Check yours with `ping -i 0.05 -c 200 <router>` on battery vs plugged in.
- **Bluetooth LE alone is slower** (~15 ms connection interval) **but doesn't share the Wi-Fi radio's stalls.** Racing both paths keeps Wi-Fi's median and BLE's tail.
- **Touch pipeline:** iOS adds a fixed ~12.3 ms from touch sample to app. The 60 Hz cap is removed (`CADisableMinimumFrameDurationOnPhone` plus a 120 Hz display link while touching), doubling updates to ~110/s.
- **Mac injection:** ~0.1–0.2 ms.
- **Predicted touches** cut ~8–12 ms but felt jittery, so they're off by default (Settings › Predictive pointer).

What removed the jitter:

- velocity-smoothed pointer acceleration (~30 ms)
- on the Mac, late packets (>12 ms) glide in at 240 Hz instead of jumping

### How racing works

- **Pointer:** packets carry *cumulative* position, so a lost or late copy can't lose or double motion.
- **Clicks, keys and scrolls** are numbered. They go over TCP plus an encrypted BLE copy. The Mac runs each number exactly once, in order.

### Measuring

- **Live telemetry:** the Mac writes stats from both apps to `~/Library/Logs/Flick/perf.log` every 5 s. It records timings and counts, never typed text.
- **Full benchmark:** with the phone paired, run `xcrun devicectl device process launch --terminate-existing --device <UDID> <iOS bundle ID> -- -bench`. It measures UDP/BLE echo at 5 and 120 Hz, TCP, the pointer race, the input race, and Bonjour browsing on vs off.
- **AWDL off for an A/B:** `defaults write <Mac bundle ID> peerToPeer -bool false`, or the iOS Settings toggle, or launch either app with `-nop2p`.
- **UI without a Mac:** launch the iOS app with `-demo`.

## Background research

### Alternative app stores don't avoid the developer fee
EU (DMA) and Japan (MSCA) alternative marketplaces still require every app to be notarized by Apple, which requires Apple Developer Program membership. They're also region-locked.

### The iPhone can't pose as a Bluetooth mouse or keyboard
An iOS app can't publish the HID-over-GATT service (`0x1812`). CoreBluetooth rejects it with *"The specified UUID is not allowed for this operation"*, and Apple has confirmed in its developer forums that apps may not publish HOGP. Classic Bluetooth HID isn't exposed to apps either. So a small Mac companion is required, and text-field detection needs one anyway, since the phone can't see the Mac's UI.

### How Sidecar and Universal Control feel seamless
- **Discovery:** Continuity BLE advertisements, tied to the same iCloud account.
- **Data path:** AWDL, Apple's peer-to-peer Wi-Fi.
- **Identity:** iCloud keys replace pairing codes.

The Continuity protocols are private, but AWDL is available through Network.framework, which Flick uses.

## Source layout

```
Shared/Protocol.swift        wire protocol, TLS credentials, UDP packet format, framing
Shared/Keychain.swift        pairing secrets in the Keychain
Mac/FlickMacApp.swift        menu bar UI, PIN, permissions
Mac/Server.swift             Bonjour/AWDL listeners, pairing, session handling, input racing
Mac/InputInjector.swift      CGEvent mouse/scroll/keyboard injection
Mac/FocusWatcher.swift       Accessibility-based text-field detection
Mac/BLEReceiver.swift        Bluetooth LE path (Mac side)
Mac/SpaceSwitcher.swift      instant Space switching (see Credits in the README)
Mac/DockProvider.swift       the Mac's Dock apps, for the phone's app switcher
iOS/FlickApp.swift           SwiftUI shell: discovery, PIN entry, settings
iOS/RemoteClient.swift       discovery, connection, pairing key, UDP motion channel
iOS/TouchpadView.swift       raw-touch trackpad, momentum scrolling, Space swipes
iOS/KeyboardController.swift keyboard proxy and diffing
iOS/ControlView.swift        the trackpad screen and accessory bar
iOS/BLESender.swift          Bluetooth LE path (phone side)
iOS/MotionSender.swift       pointer racing over UDP and BLE
iOS/Benchmark.swift          on-device latency benchmark (-bench)
Design/                      master SVGs for the icons; run Design/render-icons.sh after editing
```
