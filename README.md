<div align="center">

<img src="docs/assets/icon.png" width="128" alt="XSide icon">

# XSide

**Sideload iOS apps from your Mac's menu bar, and never let them expire.**

Free Apple Account · Xcode's own tools · Auto-refresh over USB or Wi-Fi

[![macOS 15+](https://img.shields.io/badge/macOS-15%2B-000000?style=flat-square&logo=apple&logoColor=white)](#-requirements)
[![Swift 6](https://img.shields.io/badge/Swift-6-F05138?style=flat-square&logo=swift&logoColor=white)](https://swift.org)
[![Xcode](https://img.shields.io/badge/Xcode-required-147EFB?style=flat-square&logo=xcode&logoColor=white)](https://developer.apple.com/xcode/)
[![License: MIT](https://img.shields.io/badge/License-MIT-8B5CF6?style=flat-square)](LICENSE)
[![Release](https://img.shields.io/github/v/release/Antholife/xside?include_prereleases&style=flat-square&color=8B5CF6)](https://github.com/Antholife/xside/releases)
[![Free Apple Account](https://img.shields.io/badge/Apple%20Account-free-FFD84D?style=flat-square)](#-apples-limits-with-a-free-account)

**English** · [Français](README.fr.md)

</div>

---

XSide installs `.ipa` files on your iPhone and iPad with a free Apple Account, then re-signs and reinstalls them before Apple's 7-day expiry, quietly, from the menu bar.

> [!WARNING]
> **XSide is in beta.** This is a pre-release: some bugs may still show up (though it's been holding up well so far), and not every planned feature is in yet. Found something odd? [Open an issue](https://github.com/Antholife/xside/issues).

> [!NOTE]
> XSide never asks for your Apple password. Signing goes through the account you already added in Xcode, using Xcode's own tools: `xcodebuild`, `codesign` and `devicectl`.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/assets/screenshots/panel-dark.png">
    <img src="docs/assets/screenshots/panel-light.png" width="380" alt="The XSide panel under the menu bar icon: apps with their icon and days left">
  </picture>
</p>

<p align="center">
  <img src="docs/assets/screenshots/install-dark.png" width="370" alt="The install window: devices as tiles and options">
  <img src="docs/assets/screenshots/installing-dark.png" width="370" alt="Installing: the app's icon in a progress ring and the steps">
</p>

<p align="center">
  <img src="docs/assets/screenshots/settings-dark.png" width="370" alt="Settings: a sidebar of pages; Xcode and signing all set">
  <img src="docs/assets/screenshots/updates-dark.png" width="370" alt="Settings: automatic updates (Sparkle), how often and the channel">
</p>

## ✨ Features

| | |
|---|---|
| 📥 **Drop to install** | Drop an `.ipa` onto the menu-bar icon, or pick one, and install it on one or several devices. |
| ✅ **Checks before installing** | An iOS too old for the app, a device already holding its 3 apps (uninstall one right there), no App ID left: you know before. |
| 🔄 **Auto-refresh** | Apps are refreshed before they expire (1, 2 or 3 days, your choice), over USB or Wi-Fi (per device), or all at once with *Refresh all*. Pause, only on power adapter, at night or in the evening: an app about to expire is always refreshed. |
| 🏷️ **XSide in your apps** | Each app says where it comes from and until when it works: a sheet after an install, a bar when you open it ("Valid for 5 more days", orange or red when XSide couldn't refresh it in time), a card after a refresh, a reminder the day before it expires, and an *XSide Settings* page in its iOS Settings. |
| 🎚️ **Settings that follow you** | Each app has its own XSide settings per device (validity bar, late alert, card, reminder, language, automatic refresh), changed on the iPhone or on the Mac, and kept in step: the most recent change wins. The app's *XSide Settings…* window says where each change stands, device by device. |
| 👆 **Refresh from the iPhone** | Touch and hold an app's icon: *Refresh now*, *XSide Settings*, *Report a problem*. XSide answers its apps over the local network (signed, private to each app); turning off *Automatic refresh* in the app's iOS Settings pauses it. macOS may ask once to allow incoming connections. |
| 🪜 **A guided install window** | Three steps (Devices, Install, XSide in the app), every option explained with a preview and where to change it later. *Review the options at each install* can be turned off for apps already installed. |
| 🧩 **Install as it came** | For an app that refuses to launch because it detects a change: install it without XSide features, per app or for all. XSide still refreshes it. |
| 🛡️ **Trust in one tap** | After an install, XSide opens the app on the device; if the device doesn't trust the developer yet, it opens the right Settings page there. |
| 🗑️ **Deleted stays deleted** | An app deleted from the device is removed from XSide's list, never reinstalled. |
| 🔔 **Never miss an expiry** | Reminders, a badge on the menu-bar icon, and notifications with *Refresh now* and *Open XSide* buttons. |
| 📱 **At a glance** | A panel under the menu-bar icon: each app's own icon, its devices, the days left, and the week's App IDs as a strip. |
| 📊 **Real progress** | Percentages while signing, time spent while sending to the device, and the percentage on the Dock icon. |
| 🎛️ **Per-app controls** | Refresh now, pause refreshing, or uninstall from the device. |
| ⬆️ **Updates itself** | New versions arrive automatically (Sparkle, signed); choose how often and the channel. |
| 🧭 **Guided setup** | A first-launch walkthrough: Xcode, Apple Account, signing certificate, notifications, devices. |
| 🐞 **Easy bug reports** | *Report a problem* opens the GitHub bug form already filled in, and saves the full log on your Desktop to attach. Personal details are masked. |
| 🌍 **Localized** | English and French. |

## ⚙️ How it works

```mermaid
flowchart LR
    A[".ipa"] --> B["Provisioning profile<br/>(xcodebuild)"]
    B --> C["Re-sign<br/>(codesign)"]
    C --> D["Install<br/>(devicectl)"]
    D --> E["📱 iPhone / iPad"]
    E -. "2 days before expiry" .-> B
```

## 📋 Requirements

- A Mac with **macOS 15 or later**.
- **Xcode**, installed in `/Applications` and opened once.
- An **Apple Account** added in *Xcode > Settings > Apple Accounts*. A free account is enough.
- **Developer Mode** enabled on the device, and the device paired with the Mac once over USB.

> [!TIP]
> If your iPhone runs an iOS beta, you need the matching Xcode beta, from [developer.apple.com/download/applications](https://developer.apple.com/download/applications/).

Windows and Linux aren't supported: XSide relies on Xcode, which only runs on macOS.

## 🍎 Apple's limits with a free account

| Limit | What it means |
|---|---|
| ⏳ **7 days** | Apps expire after a week. XSide refreshes them before that, as long as it keeps running in the menu bar. |
| 📱 **3 apps** | At most 3 sideloaded apps per device. |
| 🆔 **10 App IDs / 7 days** | XSide shows an estimate of what's left: Apple doesn't expose the real count. |
| 🧩 **No extensions** | Widgets, share extensions and Watch apps are removed before signing. |

## 🚀 Install

1. Download `XSide-<version>.zip` from the [latest release](https://github.com/Antholife/xside/releases).
2. Unzip it, move `XSide.app` to `/Applications` and open it.

Runs on Apple silicon and Intel Macs. To build it yourself instead:

```sh
git clone https://github.com/Antholife/xside.git
cd xside
scripts/bundle.sh   # builds build/XSide.app
```

> [!IMPORTANT]
> The app isn't notarized. If macOS blocks it, go to **System Settings > Privacy & Security** and click **Open Anyway**.

Keep XSide running in the menu bar (turn on *Launch at login* in its settings): that's what refreshes your apps. XSide then updates itself (Sparkle), from *Settings > Updates*.

## ⌨️ Command line

Turn it on in *Settings > General > Command line tool*, then:

```sh
xside status                     # apps, devices and days left (--json too)
xside refresh youtube            # refresh an app now (name or bundle id, partial is fine)
xside refresh --all              # every app that can be now
xside pause 2h                   # pause automatic refreshes (2h, 30m, 1d; none: until resumed)
xside resume                     # resume them
xside install ~/Downloads/a.ipa  # open it in the install window
```

If XSide isn't running, `xside` starts it in the background first. XSide always does the signing itself, so the two never sign at once.

## 🛠️ Development

```sh
swift build                      # build
swift test                       # core logic tests (Sources/XSideCore)
CONFIG=debug scripts/bundle.sh   # build/XSide-debug.app, a separate app with its own data
scripts/check-strings.sh         # English and French strings match
```

## 📝 Changelog

See [CHANGELOG.md](CHANGELOG.md) for what changed in each version.

## 📄 License

[MIT](LICENSE) · Made by [Antholife](https://github.com/Antholife)
