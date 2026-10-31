# Changelog

All notable changes to XSide. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- **Automatic updates** with [Sparkle](https://sparkle-project.org): XSide checks once a day and offers new versions, signed with the project's EdDSA key. *Settings > Updates* to turn it off or check now. Versions before this one have to be updated by hand once.
- The panel is a real popover, with its arrow under the menu-bar icon, and a new look: Install / Refresh all tiles, each app's own icon, icon footer (Settings, What's New, logs, GitHub, report a bug) with hover labels.
- Settings redone with a sidebar, one short page per topic; update check frequency (daily, weekly, monthly) and channel (beta; stable opens with 1.0).
- Change the app right from the install window, with a button or by dropping another `.ipa` on it.

### Fixed
- Removing a device that is still paired now hides it until an app is installed on it again.
- The panel closes before quitting and before the "Remove this device" confirmation.

## [1.0.2-beta] - 2026-10-30

### Added
- **Logs**: every command, install, refresh and uninstall step is written to `~/Library/Logs/XSide`, with e-mail, team, certificate and devices masked. *Settings > Logs* shows or exports them.
- **Export logs** link under install failures: a zip with the logs and a state summary, ready to attach to an issue.
- GitHub bug report template.

### Fixed
- `.ipa` files patched after the fact (stray bytes between zip entries) couldn't be unzipped: `ditto` gave up with "Couldn't read pkzip signature". XSide now falls back to `unzip`, under the same safety checks. ([#1](https://github.com/Antholife/xside/issues/1))
- The person's name in a signing certificate is masked in the logs too.

### Thanks
- [@parmagit](https://github.com/parmagit) again, for sharing the `.ipa` that helped find this one.

## [1.0.1-beta] - 2026-10-30

### Added
- **What's New window**: after each update, XSide shows what changed. Also in *Settings > About*.
- When an `.ipa` is refused, the message now gives the exact reason, for bug reports.

### Fixed
- Some `.ipa` files were refused as invalid ("This file isn't a valid app"): their folders are stored without the search permission (`rw-r--r--`), and the safety check took them for an attack. XSide now restores the permissions after unzipping and still checks the real size. ([#1](https://github.com/Antholife/xside/issues/1))

### Thanks
- [@parmagit](https://github.com/parmagit) for reporting the refused `.ipa` files and helping track down the cause.

## [1.0.0-beta] - 2026-10-30

First public beta.

### Added
- Install an `.ipa` on one or several iPhones and iPads with a free Apple Account, using Xcode's own tools (`xcodebuild`, `codesign`, `devicectl`). XSide never asks for your Apple password.
- Drop an `.ipa` onto the menu-bar icon, or pick one.
- Automatic refresh 2 days before expiry, over USB or Wi-Fi (per device).
- Expiry reminders, a badge on the menu-bar icon and notifications that open the right fix.
- Per-app menu: refresh now, pause refreshing, uninstall from the device.
- Cancel an install, and follow its progress from the popover.
- Guided setup: Xcode, Apple Account, signing certificate, notifications, launch at login, devices.
- Settings for Xcode and signing, with a status and a fix for each issue.
- English and French.
- Universal app: Apple silicon and Intel.

[1.0.2-beta]: https://github.com/Antholife/xside/compare/v1.0.1-beta...v1.0.2-beta
[1.0.1-beta]: https://github.com/Antholife/xside/compare/v1.0.0-beta...v1.0.1-beta
[1.0.0-beta]: https://github.com/Antholife/xside/releases/tag/v1.0.0-beta
