# App Store listing: Flick for iPhone

Everything to paste into App Store Connect for the first submission. Field limits are noted, and every entry is within them.

## Before you submit

1. **Publish a Mac release first** (`scripts/release-mac.sh 1.0.0 --publish`; see [RELEASING.md](../RELEASING.md)). App Review needs the Mac app to test the iPhone app, and the review notes point them to the install command.
2. **Record a short demo video** (under a minute) showing pairing and using the phone to control a Mac. Upload it somewhere the reviewer can watch without signing in, such as an unlisted YouTube video, and put the link in the review notes. Reviewers sometimes can't test hardware-dependent apps, and a video avoids a rejection round.

## App information

| Field | Value |
|---|---|
| Name (30) | **Flick: Mac Remote** |
| Subtitle (30) | Trackpad & keyboard for Mac |
| Bundle ID | `com.jacobwoliver.flick` |
| SKU | `flick-ios` |
| Primary category | Utilities |
| Secondary category | Productivity |
| Content rights | Doesn't contain, show or access third-party content |
| Age rating | 4+ (answer "None" or "No" to every question) |
| Price | Free |
| Copyright | 2026 Jacob Woliver |

> **About "Mac" in the name.** Apple's trademark guidelines allow "Mac" when it describes compatibility ("…for Mac"). App Review sometimes rejects names that use Apple trademarks in other ways, under guideline 5.2.5. If "Flick: Mac Remote" is rejected, the safer fallback is **Flick: Remote for Mac** (21 characters).

## URLs

| Field | Value |
|---|---|
| Support URL | https://getflick.net/support |
| Marketing URL | https://getflick.net |
| Privacy Policy URL | https://getflick.net/privacy |

## Promotional text (170)

Control your Mac from your iPhone: a full-size trackpad, a keyboard that opens when you click a text field, and one-handed scrolling and Spaces.

## Description (4,000)

Flick turns your iPhone into a trackpad and keyboard for your Mac.

Point, click, drag and scroll the same way you would on a MacBook trackpad. When you click into a text field on your Mac, the iPhone keyboard opens on its own, with autocorrect, swipe typing and dictation. Click away and it closes.

USE IT WITH ONE HAND
• Slide your thumb along the side edge to scroll.
• Slide along the bottom edge to switch between Spaces.
• Swipe up from the bottom for Mission Control.

SWITCH APPS
Your Mac's Dock is on your phone. Tap an app to bring it to the front.

SHORTCUTS
⌘C, ⌘V, undo, find and your own shortcuts are one tap away, with esc, tab, the arrow keys and modifier keys always on hand.

FAST
Every movement goes over Wi-Fi and Bluetooth at the same time, and your Mac uses whichever arrives first.

PRIVATE
No accounts, no servers and no tracking. Your iPhone talks only to your Mac, over an encrypted connection that you pair once with a PIN.

REQUIRES FLICK FOR MAC
Flick needs the free Flick for Mac app (macOS 14 or later). Get it at getflick.net.

Flick is free and open source.

## Keywords (100)

```
trackpad,mouse,keyboard,remote,control,touchpad,macbook,mission control,spaces,typing,presenter
```

## App Privacy

Choose **"Data Not Collected"**. Flick has no analytics or servers, and the iPhone sends input only to the user's own Mac. This matches `iOS/PrivacyInfo.xcprivacy` and the privacy policy.

## Export compliance

Already answered in the app (`ITSAppUsesNonExemptEncryption = NO`), so App Store Connect won't ask. Flick only uses encryption built into iOS (TLS from Network.framework, and CryptoKit). Confirm you're comfortable with that declaration; it's legally yours.

## Notes for App Review

> Flick is a companion app: it controls a Mac running the free Flick for Mac app, which we distribute ourselves (notarized by Apple) at https://getflick.net.
>
> To test:
> 1. On a Mac with macOS 14 or later, open Terminal and run:
>    curl -fsSL https://getflick.net/install.sh | bash
>    (or download Flick-macOS.zip from https://github.com/jmwoliver/flick/releases/latest)
> 2. When Flick for Mac opens, allow Local Network access, and turn on Flick in System Settings › Privacy & Security › Accessibility. Accessibility is what lets it move the pointer and type.
> 3. Click the Flick icon in the Mac's menu bar to see a 6-digit PIN.
> 4. On the iPhone, open Flick (allow Local Network access), tap the Mac, and enter the PIN. The iPhone and Mac should be on the same Wi-Fi network.
> 5. Move a finger on the iPhone to move the Mac's pointer; tap to click. Click into any text field on the Mac and the iPhone keyboard opens.
>
> A demo video: <LINK>
>
> No account or sign-in is needed. Local Network is used to find and connect to the Mac; Bluetooth is a second, faster path for pointer movement. Flick collects no data.

## Screenshots

6.9" iPhone (1320 × 2868), in [screenshots/](screenshots/):

1. `1-trackpad.png`: the trackpad with gesture hints and the Mac's Dock.
2. `2-keyboard.png`: typing into a Mac note with the iPhone keyboard.

They come from the app's demo mode (`-demo`, `-demoKeyboard`) on an iPhone 17 Pro Max simulator, so they don't show a real Mac's name. App Store Connect scales them for smaller iPhones.
