# Changelog

All notable changes to XSide. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- The install window's device tiles say what stops an install there: "Developer Mode off", or "Unlock it" after an attempt failed on a locked device.

- An app deleted from the device (home screen) is no longer put back by the next refresh: XSide sees it's gone (before a refresh, every 10 minutes on each reachable device, and when the panel opens), removes it from its list for that device, drops its expiry reminder and says so in a notification.

- After an install, XSide opens the app on the device, which also tells whether the device trusts the developer. Not trusted: the "trust the developer" guide shows and XSide opens Settings > General > VPN & Device Management on the device itself (a button opens it again). Trusted: no guide. When the device can't tell (locked), the guide shows on a first install, after the last XSide app was deleted from the device, or with a new certificate.

- Apps installed with XSide show who installed them: after an install, a sheet with the XSide logo, the expiry date and the days left (once per signature, in its own window so the app's screens can't cover or close it); after a refresh, a smaller card at the bottom instead, closed with OK. Added during a new install step, "Adding XSide features", which lists them.
- Apps also remind on the device itself, 24 h before they expire. If the app never asked for notifications, that permission is asked once, when the install sheet is closed (never again after an answer); the sheet says why beforehand.

- Each app's page in the iOS Settings app (Settings > the app) gets an "Installed with XSide" section: valid until, last refreshed, and a link to XSide. Rewritten at each refresh; the app's own settings stay as they were.

- *Settings > General > Automatic refreshes*: refresh apps 1, 2 (default) or 3 days before they expire; pause them (1 hour, until tomorrow morning, until resumed); only on power adapter; a preferred time (night or evening). An app expiring within 12 hours is refreshed anyway, and manual refreshes are never held back. The panel has a **Pause** tile too, and says while refreshes are paused.
- **Report a problem** (*Settings > Logs*, and the bug button in the panel): opens XSide's bug form on GitHub, filled in with XSide's state and the last log lines, and saves the full diagnostics archive in Downloads to drag into it. Everything is masked (device names, identifiers, accounts) and nothing is sent until you submit.
- *Settings > General > Installs and devices*: open the app after an install, open the Trust page when the device needs it (both defaults, changeable in each install's Options), notice apps deleted from the device, and refresh new devices over Wi-Fi or not. *Settings > Notifications* can turn off the reminder on the device and the notification when a deleted app leaves the list.

### Fixed
- On-device reminders in tweaked apps that pretend to be another app (e.g. a modded YouTube reporting "com.google.ios.youtube" for Google sign-in): iOS refused them notifications without asking. XSide now asks with the app's real identity, and an app name with special characters ("YouTube +") gets a plain internal name.
- A device with Developer Mode off: the install window says so and how to turn it on, and doesn't start an install that can only fail. If it fails anyway, the message says Developer Mode is off instead of "Couldn't create the provisioning profile".
- A device out of reach during an uninstall (CoreDevice error 1011) is reported as unreachable, not as a failed uninstall.
- A locked device that Xcode has to prepare for development: the message says to unlock it, instead of "Couldn't create the provisioning profile".

## [1.0.4-beta] - 2026-11-03

### Added
- **Command line tool** `xside`: `status`, `refresh <app>`, `refresh --all`, `install <file.ipa>`, `open`. Installed from *Settings > General*; starts XSide in the background when it isn't running.
- **Update notifications**: a new version found in the background shows a notification and a banner in the panel, instead of a window that could open behind others.
- **Install updates automatically** (*Settings > Updates*): downloaded in the background and installed as soon as nothing runs; XSide relaunches itself, then says "XSide x.y was installed".
- Sparkle's update window shows the version's changelog.

### Fixed
- When Xcode drops its Apple Account (a known Xcode bug), one notification instead of one each time it flickers back; the message says what happened.
- "Open Xcode" says to press ⌘ + comma or use the Xcode > Settings… menu (its Settings then open on Apple Accounts), since Xcode can't be opened straight on them.
- A beta Xcode counts as ready only once its license is accepted, and isn't checked again at every probe.
- The panel's footer buttons show their hover color and label again.
- The quit confirmation no longer holds up an update relaunching XSide.
- Sparkle's "Version History" opens the page of all releases.

## [1.0.3-beta] - 2026-10-31

### Added
- **Automatic updates** with [Sparkle](https://sparkle-project.org): XSide checks once a day and offers new versions, signed with the project's EdDSA key. *Settings > Updates* to turn it off or check now. Versions before this one have to be updated by hand once.
- The panel is a real popover, with its arrow under the menu-bar icon, and a new look: Install / Refresh all tiles, each app's own icon, icon footer (Settings, What's New, logs, GitHub, report a bug) with hover labels.
- Settings redone with a sidebar, one short page per topic; update check frequency (daily, weekly, monthly) and channel (beta; stable opens with 1.0).
- Change the app right from the install window, with a button or by dropping another `.ipa` on it.
- The install window redone: the app on a gradient header, devices as tiles, options as rows, and while installing the app's icon in a progress ring with the steps below.
- **Checks before installing**: an iOS too old for the app, a device already holding its 3 apps (uninstall one right there), no App ID left this week.
- **Notification buttons**: "Refresh now" and "Open XSide" on expiry reminders and refresh failures; the app glows in the panel.
- **Real progress**: percentages for the unzip and the signing, time spent and size while sending to the device; on the Dock icon too.
- The week's App IDs as a strip in the panel, with when the next one frees up.
- **Keep in the Dock**, synced with the Dock's own setting; a click on the Dock icon opens the install window.

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

[1.0.4-beta]: https://github.com/Antholife/xside/compare/v1.0.3-beta...v1.0.4-beta
[1.0.3-beta]: https://github.com/Antholife/xside/compare/v1.0.2-beta...v1.0.3-beta
[1.0.2-beta]: https://github.com/Antholife/xside/compare/v1.0.1-beta...v1.0.2-beta
[1.0.1-beta]: https://github.com/Antholife/xside/compare/v1.0.0-beta...v1.0.1-beta
[1.0.0-beta]: https://github.com/Antholife/xside/releases/tag/v1.0.0-beta
