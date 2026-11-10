# AGENTS.md

Instructions for AI coding agents (Codex, Claude Code, Cursor, Copilot, ...) and humans contributing to XSide.

## What XSide is

- A macOS menu-bar app (Swift Package) that sideloads IPAs onto iPhones and iPads with a free Apple account.
- It uses Xcode for provisioning (App IDs, profiles) and `devicectl` for installs, and refreshes the apps before the 7-day expiry.
- At install it injects an iOS dylib (built from `App/Welcome/*.m`) that shows a pill, a card, a reminder, an in-app Settings page, and talks back to the Mac over the local network.

## Repo map

- `Sources/XSideCore/`: all the logic, UI-free and unit tested (planner, pipeline, resigner, Mach-O patcher, provisioning, devices, channel protocol in `Channel.swift` and `ChannelHandler.swift`, settings, library/state).
- `Sources/XSideApp/`: the menu-bar app (SwiftUI/AppKit): views, `AppModel`, `BackgroundEngine`, `ChannelServer`, `Updater` (Sparkle), `L10n`.
- `Sources/XSideCLI/`: the `xside` command-line tool.
- `App/Welcome/`: the injected iOS dylib (Objective-C). `XSChannelCore.m` and `XSSettingsCore.m` are also compiled on the Mac to be tested.
- `App/Resources/en.lproj`, `App/Resources/fr.lproj`: `Localizable.strings`, `Localizable.stringsdict`, `ServicesMenu.strings`. `App/Info.plist`, `App/XSide.entitlements`.
- `scripts/`: `bundle.sh`, `check-strings.sh`, `test-welcome-hmac.sh` (+ `.m`), `release.sh` (maintainer), `changelog-html.py`, `make-icons.swift`.
- `Tests/XSideCoreTests/`: Swift Testing suites (`import Testing`) and `Fixtures/` (including `channel-fixture.json`).
- `.github/ISSUE_TEMPLATE/`, `README.md` / `README.fr.md`, `CHANGELOG.md`, `appcast.xml`.

## Prerequisites

- A Mac with **macOS 15 or later** and **Xcode** in `/Applications`, opened once (Swift 6 toolchain; `swift --version` should say 6.x).
- For anything that touches devices, signing or the injected dylib: an **iPhone or iPad** with **Developer Mode** on, paired with the Mac once over USB, and an **Apple Account** in *Xcode > Settings > Apple Accounts* (a free account is enough). With an iOS beta, use the matching Xcode beta.
- Logic-only changes (`XSideCore`) need no device: `swift test` covers them.

## Your first change, step by step

1. Fork `Antholife/xside` on GitHub, clone your fork, and branch from `main`: `git checkout -b fix/short-name`.
2. Build and run the debug app: `CONFIG=debug scripts/bundle.sh && open build/XSide-debug.app`. It sits in the menu bar next to the real XSide (if you have it) without sharing anything with it.
3. Make the change. Logic goes in `Sources/XSideCore` with a test written first; UI goes in `Sources/XSideApp/Views`; strings in both `en.lproj` and `fr.lproj`.
4. Run the checks (see *Build and test*), rebuild the debug app, and try the change by hand.
5. Add the `CHANGELOG.md` `[Unreleased]` line, commit with a short imperative message, push to your fork, and open a PR against `main` with what changed, why, and how you tested it (device and iOS version if relevant). Tick the checklist below.

## Testing on a device without breaking your own apps

- The debug app (`io.github.xside.XSide.debug`) keeps its own library (`~/Library/Application Support/XSide-debug`), settings and notifications; logs are in `~/Library/Logs/XSide-debug`. It never updates itself.
- Your **iPhone is shared**, though: if the debug app installs an app that the real XSide also manages (same bundle ID, same Apple Account), it replaces that app on the device and both copies of XSide will try to refresh it. Test with an IPA the real XSide doesn't manage, or use *Stop refreshing* on that app in the real XSide (its … menu in the panel) while you test, and *Resume refreshing* afterwards.
- A free Apple Account allows **3 sideloaded apps per device** and **10 new App IDs per 7 days**. Reuse the same test IPA instead of installing many different ones.
- Tweaks: `scripts/make-tweak-test-kit.sh` (run `scripts/build-unzstd.sh` first; `XST_CRASH=1` adds crash.deb) builds an unsigned test app (io.github.xside.tweaktest, lines that say "no" until a tweak changes them) and ✅/🔧/❌ test tweaks. Sources in `scripts/tweak-test-kit/`.
- Never put a debug or locally built app in `/Applications`: that's where the released app lives and updates itself.
- Debug-only hooks: `XSIDE_FAKE_NO_DEVICES=1`, `XSIDE_FAKE_PREFLIGHT=1`, `XSIDE_FAKE_ENV_FILE=<file>` (see `Sources/XSideApp/AppModel.swift`) show screens that are hard to reach for real. Build-time: `XSIDE_TEST_REMINDER=1` fires the iPhone reminder 1 minute after launch, `XSIDE_TEST_LATE=1` forces the late state; never ship or commit those builds.

## Build and test

```sh
swift build
swift test                        # logic tests (XSideCore)
scripts/check-strings.sh          # en/fr keys match, plists lint
scripts/test-welcome-hmac.sh      # dylib channel/settings code vs. the Swift fixture
scripts/test-icloud-shim.sh       # iCloud signed-out shim (App/ICloud) against CloudKit on the Mac
scripts/test-tweak-support.sh     # tweak path redirect (App/TweakSupport): C core vs. the Swift fixture, the library on the Mac
scripts/bundle.sh                 # build/XSide.app (release, arm64 + x86_64)
CONFIG=debug scripts/bundle.sh    # build/XSide-debug.app: own bundle id (io.github.xside.XSide.debug), own data dir, XSIDE_FAKE_* test hooks, no update feed
```

Use the debug app for manual testing; it does not touch the real app's data. Run all three checks (`swift test`, `check-strings.sh`, `test-welcome-hmac.sh`) before opening a PR; run `test-welcome-hmac.sh` whenever `App/Welcome` or the channel changes.

Pinned third-party sources (built from source, never vendored binaries): `scripts/fetch-pinned.sh` + `scripts/ellekit.env` (ElleKit) and the zstd pin in `scripts/build-unzstd.sh`. Bump a pin only in a dedicated PR.

## Rules for a PR

1. **Strings in English and French, wherever they live.** Every user-facing text exists in both languages, in the place its kind of text lives:
   - the Mac app and the CLI: `App/Resources/en.lproj` and `fr.lproj` (`Localizable.strings`, `.stringsdict`); `scripts/check-strings.sh` must pass (it only checks these);
   - the injected dylib: inline in `App/Welcome/*.m`, both languages side by side (`XST(fr, en)` or `fr ? … : …`); it can't read the Mac's lproj files;
   - the app's iOS Settings page: `Sources/XSideCore/XSideSettingsSection.swift`; the local-network usage text: `Sources/XSideCore/InfoPlistAdditions.swift`.
   Never add a user-visible text in one language only.
2. **CHANGELOG.** Add an entry under `## [Unreleased]` in `CHANGELOG.md` (Added / Changed / Fixed), in the existing style: user-facing wording, one bullet, bold lead phrase for features. No entry for pure refactors or tests.
3. **Tests for logic.** Put logic in `XSideCore` and test it in `Tests/XSideCoreTests`. Work test-first: write the failing test, then the code. UI-only changes in `XSideApp` need no unit test but must be tried in the debug app.
4. **The dylib stays inert and safe in hosts.** It runs inside third-party apps: never crash or throw, never block the main thread, do nothing harmful when something is missing, and degrade silently. Read facts (bundle id, version, name, ...) from the `Info.plist` file on disk, not from `NSBundle`: tweaks fake what `NSBundle` reports (see `XSInfo()` and the real-bundle-id logic in `App/Welcome/XSCommon.m`).
5. **Do not weaken the local-network channel.** The protocol is documented at the top of `Sources/XSideCore/Channel.swift`: per-installation secret, HMAC-SHA256 over the framed request, nonces (replay cache), a +-120 s time window, connection limits (16 in all, 4 per peer; verified `watch` connections that stay open: at most 8 in all, 2 per address, one per installation, pushed lines signed with the watch nonce and a strict line number; optional signed fields such as `pollEvery`, `previousRunEnded`/`previousRunSince` (check-in), `saysBye` (watch) and `pausedUntil` (replies) are part of the signed body; a watch may end with one sealed `bye` request (own nonce, max 4 KB) — anything else on a watch closes it; 20 accepts per minute per peer, 64 KB lines, 10 s read timeout; `Sources/XSideCore/ChannelAdmission.swift`, used by `Sources/XSideApp/ChannelServer.swift`), unsigned `rejected` for anything that fails. Any change to the frame format must update the Swift side, `App/Welcome/XSChannelCore.m`, and `Tests/XSideCoreTests/Fixtures/channel-fixture.json` together, with `swift test` and `scripts/test-welcome-hmac.sh` both green. Do not loosen checks, enlarge the window, or skip authentication to make a test pass.
6. **Logic that exists twice changes together.** The settings merge and visibility rules live in `Sources/XSideCore/InAppSettings.swift` and in their port `App/Welcome/XSSettingsCore.m` (the channel framing likewise in `Channel.swift` and `XSChannelCore.m`; the tweak path mapping in `Sources/XSideCore/TweakPaths.swift` and `App/TweakSupport/XSTweakPathsCore.c`). Change both and keep `scripts/test-welcome-hmac.sh` green.
7. **Never commit** build outputs (`.build/`, `build/`), test builds (anything built with `XSIDE_TEST_REMINDER=1` or `XSIDE_TEST_LATE`, which `release.sh` refuses), `spikes/`, or anything under `docs/superpowers/` or `.superpowers/` (all git-ignored; keep it that way).
8. **No secrets.** No Apple ID, team ID, tokens, signing keys, Sparkle EdDSA keys, device UDIDs or personal paths in code, fixtures, logs or commit messages. Sanitize logs and reports you paste.
9. **Release is maintainer-only.** Do not edit `appcast.xml`, the version in `App/Info.plist`, or `scripts/release.sh`, and do not tag or publish releases.
10. Keep changes focused; follow the surrounding Swift/Objective-C style; do not add dependencies without discussing them in an issue first.

## PR checklist

- [ ] `swift test`, `scripts/check-strings.sh` and (if `App/Welcome` or the channel changed) `scripts/test-welcome-hmac.sh` pass
- [ ] New or changed strings exist in `en` and `fr`
- [ ] Logic has tests; the UI was tried in `CONFIG=debug scripts/bundle.sh`
- [ ] `CHANGELOG.md` `[Unreleased]` updated
- [ ] Channel security unchanged (or fixture + both sides updated)
- [ ] No build output, test-reminder build, `docs/superpowers`, `.superpowers` or secret in the diff
- [ ] `appcast.xml` and release files untouched
