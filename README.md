# XSide

**English** · [Français](README.fr.md)

XSide is a macOS menu-bar app that sideloads `.ipa` files onto your iPhone and iPad with a free Apple Account, and refreshes them automatically before Apple's 7-day expiry.

It only uses Xcode's own tools (`xcodebuild`, `codesign`, `devicectl`). XSide never asks for your Apple password: signing goes through the account you already added in Xcode.

## Features

- Drop an `.ipa` onto the menu-bar icon (or pick one) and install it on one or several devices.
- Automatic refresh, over USB or Wi-Fi (per device), 2 days before an app expires.
- Expiry reminders, a badge on the menu-bar icon when something needs you, and notifications that open the right place to fix it.
- Per-app menu: refresh now, pause refreshing, uninstall from the device.
- Shows the app icon, its devices and days left at a glance.
- Guided first launch: Xcode, Apple Account, signing certificate, notifications, devices.
- English and French.

## Requirements

- A Mac with **macOS 15 or later**.
- **Xcode**, installed in `/Applications` and opened once. If your iPhone runs an iOS beta, you need the matching Xcode beta ([developer.apple.com/download/applications](https://developer.apple.com/download/applications/)).
- An **Apple Account** added in Xcode > Settings > Apple Accounts. A free account is enough.
- Developer Mode enabled on the device, and the device paired with the Mac once over USB.

Windows and Linux aren't supported: XSide relies on Xcode, which only runs on macOS.

## Apple's limits with a free account

- Apps expire after **7 days**: XSide re-signs and reinstalls them before that, as long as it keeps running in the menu bar.
- **3 sideloaded apps** at most per device.
- **10 App IDs** per 7 days. XSide shows an estimate of what's left; Apple doesn't expose the real count.
- App extensions (widgets, share extensions, Watch apps) are removed before signing.

## Install

There's no signed release yet, so build it yourself:

```sh
git clone https://github.com/Antholife/xside.git
cd xside
scripts/bundle.sh   # builds build/XSide.app
```

Move `build/XSide.app` to `/Applications` and open it. The app isn't notarized: if macOS blocks it, go to **System Settings > Privacy & Security** and click **Open Anyway**.

Keep XSide running in the menu bar (enable *Launch at login* in its settings): that's what refreshes your apps.

## Development

- `swift build` / `swift test`: the core logic lives in `Sources/XSideCore`, with tests.
- `CONFIG=debug scripts/bundle.sh` builds `build/XSide-debug.app`, a separate app (own bundle id and data) for testing.
- `scripts/check-strings.sh` checks that English and French strings match.

## License

[MIT](LICENSE) · By [Antholife](https://github.com/Antholife)
