# Releasing Flick

This covers both apps. The Mac app is distributed through GitHub releases and getflick.net; the iPhone app goes through the App Store.

## Mac app

Mac releases are GitHub releases with two files: `Flick-macOS.zip` (the signed, notarized app) and `Flick-macOS.zip.sha256`. The installer at `https://getflick.net/install.sh` downloads the latest published release, checks both files, and installs the app.

`scripts/release-mac.sh` does the whole release: build, sign, notarize, package, tag, and create the GitHub release.

### One-time setup

1. **Join the Apple Developer Program** ($99/year) at [developer.apple.com/programs](https://developer.apple.com/programs/). Approval usually takes a day or two. The same membership covers the iPhone App Store.

2. **Use your paid team in the project.** Your paid team may have a different team ID than the free "Personal Team" the project uses now (`F9UPC9VN4S`). Find it at [developer.apple.com/account](https://developer.apple.com/account) under Membership details. If it's different:
   - In Xcode, open the project and choose the new team under *Signing & Capabilities* for both the **Flick** and **FlickMac** targets.
   - Set `TEAM_ID` in `website/install.sh` to the new ID, and push. The site redeploys on its own. The installer refuses apps signed by any other team, and the release script checks the two match.

3. **Sign in to Xcode** with that Apple ID (*Settings › Accounts*). That's all signing and notarization need: during a release, Xcode creates the Developer ID certificate and notarizes the app using this account.

   Optional: to notarize with `notarytool` instead (for example from a machine without your Xcode account), create an app-specific password at [account.apple.com](https://account.apple.com) and save it with `xcrun notarytool store-credentials flick-notary --apple-id <your Apple ID email> --team-id <TEAMID>`. The release script uses that profile when it exists.

4. **Sign in to GitHub's CLI** if you haven't: `gh auth login`.

### Making a release

From an up-to-date `main` with no uncommitted changes:

```bash
scripts/release-mac.sh 0.2.0
```

This creates a **draft** release. Check it on GitHub, then publish it there. The installer only sees published releases. To publish immediately instead, add `--publish`.

The script:

1. Checks the setup: clean tree, on `main` and in sync with GitHub, tag not taken, and that `install.sh` expects your team.
2. Archives a universal (Apple silicon and Intel) Release build. The version is the one you pass; the build number is the commit count.
3. Signs it with Developer ID and submits it to Apple's notary service, using your Xcode account (or the `flick-notary` profile if you saved one).
4. Waits for notarization, then checks the signature, team, Hardened Runtime, architectures, version and stapled ticket, and confirms Gatekeeper accepts it.
5. Zips it, writes the checksum to `dist/`, tags `v0.2.0`, and creates the GitHub release.

To check a release, run the installer on a Mac:

```bash
curl -fsSL https://getflick.net/install.sh | bash
```

### Testing without a Developer ID

`scripts/release-mac.sh 0.2.0 --dev` runs the build and checks with your development certificate, and skips notarization, tagging and publishing. Use it to test changes to the pipeline.

### When notarization fails

The script saves Apple's response to `build/release/notarized.log` (Xcode account) or `build/release/notary-log.json` (`notarytool`). The usual causes are a missing Hardened Runtime, the debugging entitlement (`get-task-allow`), or something unsigned inside the app. The script checks for the first two before submitting.

### Versions

Use `major.minor.patch`. The iPhone app's version is set separately in Xcode and goes through App Store Connect.

## iPhone app

### One-time setup

1. Complete steps 1 and 2 of the Mac setup above. Make sure the **Flick** target also uses your paid team.
2. **Create the app in App Store Connect.** At [appstoreconnect.apple.com](https://appstoreconnect.apple.com), go to *Apps › + › New App*: platform iOS, name **Flick: Remote for Mac**, bundle ID `com.jacobwoliver.flick` (if it isn't listed, register it under *Certificates, Identifiers & Profiles › Identifiers*), and SKU `flick-ios`.
3. Make sure Xcode is signed in to your Apple ID (*Settings › Accounts*). The upload uses that account, and Xcode creates the distribution certificate on the first upload.

### Uploading a build

```bash
scripts/release-ios.sh
```

This archives a Release build, checks it (privacy manifest, iPhone-only, encryption declaration, permission descriptions, version), uploads it, and tags the commit `ios-<version>-<build>`. The build appears in App Store Connect › TestFlight after Apple processes it, usually 10 to 30 minutes later.

For each new App Store version, change **Version** for the Flick target in Xcode first. The build number is the commit count, so upload from a new commit each time.

`scripts/release-ios.sh --dev` archives and checks with development signing and doesn't upload.

### Submitting for review

1. Install the build from TestFlight on your iPhone and try it against a Mac running a released Flick for Mac.
2. Fill in the listing from [app-store/LISTING.md](app-store/LISTING.md), and upload the screenshots in [app-store/screenshots/](app-store/screenshots/).
3. Under *App Privacy*, choose "Data Not Collected".
4. Pick the build, paste the review notes, and **Add for Review**.

App Review needs a published Mac release to test with, so publish one first.

