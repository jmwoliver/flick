# Security

Flick for Mac can move the pointer and type on your Mac, so a flaw in how it authenticates the phone would be serious. Reports are very welcome.

## Reporting a vulnerability

Please report privately through GitHub: on this repository's **Security** tab, choose **Report a vulnerability**. Don't open a public issue for security problems.

Include what you found, how to reproduce it, and what an attacker could do with it. You'll get a reply as soon as possible, and credit in the release notes if you'd like.

## What Flick protects against

Flick is designed so that someone on the same network, or within Bluetooth range, can't:

- **Control your Mac.** The Mac accepts input only from the one paired phone. Pairing takes the PIN shown in the Mac's menu bar; after that, only the phone holding the pairing key can connect.
- **Read what you type.** Everything on the control channel is encrypted with TLS. Inputs sent over Bluetooth are encrypted separately.
- **Brute-force the PIN.** The PIN only works while no phone is paired. Wrong guesses are rate-limited (5 tries, then a pause that doubles each time). Recording a pairing session doesn't help an attacker either: the TLS key exchange (ECDHE) means the PIN can't be checked offline against captured traffic.
- **Replay old traffic.** Every session gets fresh keys, and every pointer packet and input is numbered.

## How it works

| | |
|---|---|
| Control channel | TLS 1.2, `TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256` |
| Pre-shared key | HMAC-SHA256 of the 6-digit PIN (first connection only) or of a random 256-bit pairing key (every later connection) |
| Pairing key storage | Keychain on both devices; on iOS, this device only and never synced |
| Pointer packets (UDP, Bluetooth) | HMAC-SHA256 truncated to 64 bits, per-session key, sequence numbers |
| Inputs over Bluetooth | ChaCha20-Poly1305, per-session key, sequence numbers |

## Limits

- **Someone actively attacking the network at the moment you first pair** could impersonate the Mac and try PINs against what your phone sends. Pair on a network you trust; after pairing, the PIN is no longer used.
- **The Mac app needs Accessibility permission**, which gives it broad control of your Mac. Install it only from this repository or its official releases.
- **Local malware** running as your user on the Mac can already control it, so Flick doesn't try to defend against that.
- Password fields: the Mac never reads their contents, but it can only recognize fields that identify themselves as secure, or whose labels or placeholders say "password" or "passcode".
