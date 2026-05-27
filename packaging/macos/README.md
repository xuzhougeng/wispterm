# macOS Packaging

Phantty's initial macOS distribution is a signed `.app` inside a DMG. Local
builds use ad-hoc signing; release builds should set a Developer ID identity and
notarytool keychain profile.

Ghostty reference: its macOS release workflow builds the native app, signs with
hardened runtime and entitlements, creates a DMG, notarizes with `notarytool`,
staples the DMG and app, and uses Sparkle appcast metadata for automatic
updates. Phantty keeps the same signing/notarization shape, but the initial
updater story is a manual DMG release asset selected by the existing update
checker. A full Sparkle integration should be designed when the macOS
release-update flow is ready for unattended replacement.

## Local DMG

```sh
zig build macos-dist -Dtarget=aarch64-macos
```

The default local build signs with `codesign --sign - --options runtime` and
writes:

```text
zig-out/dist/macos/phantty-macos-vX.Y.Z.dmg
```

## Release Signing

Set these environment variables before running the same build step:

```sh
export PHANTTY_MACOS_SIGN_IDENTITY="Developer ID Application: Example, Inc. (TEAMID)"
export PHANTTY_MACOS_NOTARY_PROFILE="phantty-notarytool"
zig build macos-dist -Dtarget=aarch64-macos -Doptimize=ReleaseFast
```

Create the notarytool profile outside the repo:

```sh
xcrun notarytool store-credentials phantty-notarytool --apple-id "<apple-id>" --team-id "<team-id>" --password "<app-specific-password>"
```

Validation commands:

```sh
plutil -lint zig-out/bin/Phantty.app/Contents/Info.plist
codesign --verify --strict --verbose=2 zig-out/bin/Phantty.app
codesign -dvvv --entitlements :- zig-out/bin/Phantty.app
hdiutil verify zig-out/dist/macos/phantty-macos-vX.Y.Z.dmg
spctl -a -vv --type open zig-out/dist/macos/phantty-macos-vX.Y.Z.dmg
```
