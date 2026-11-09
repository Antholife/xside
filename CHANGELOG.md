# Changelog

All notable changes to XSide. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- **iPhone Duo option: *Learn more*.** Like the iCloud option, the Duo option has a *Learn more* popover (what it does, what can go wrong, how to undo, only on an iPhone Duo), and an app that already supports the Duo gets a neutral explanation instead of "it wasn't made for this".
- **Why an app crashes, in plain words.** When XSide opens an app after installing it and the app doesn't stay open, XSide reads its newest crash report on the device and says why, in the install window and on its row in the panel: the app doesn't support iOS scenes (with what to do when the iPhone Duo option caused it), a library or a function is missing (named, the app's own or iOS's), a signature problem, a crash in the XSide module or in a tweak or library added to the app (named), iCloud, which XSide doesn't give apps, out of memory, too slow to start or not responding, or else the exception and where it happened. Each comes with what to do. On demand from an app's ... menu (*Why does it crash?*, the last 24 hours), with the technical details and a cleaned copy of the report (device, account and personal identifiers masked), and from the Terminal with `xside crash <app> [--device <name>] [--json]`. *Report a problem* includes the diagnosis and the cleaned reports. Only the few reports that may be the app's are copied from the device, into a temporary folder deleted right after reading; nothing is sent anywhere.
- **A crash you can't miss, seen almost at once.** When XSide knows an app stopped, its row in the panel shows a red box under the row, across its width ("Stopped at launch: <cause>", or "Stopped while in use: <cause>") with *See why* and *Ignore*, and a red badge on its icon; a launch crash's box goes away by itself once the app is seen running again (the XSide module checks in, or it stays up after XSide opens it), a crash while in use's once the app has since been used and closed normally, and either once a reinstall is followed by a check that finds no new crash. The install window shows a red banner with the cause, *See why*, and the fix when XSide can apply it (*Reinstall without XSide features*, *Reinstall without Duo compatibility*, *Sign and reinstall*); the crash window has the same button. Crashes that happen later are noticed within seconds or minutes: the XSide module keeps a small marker in the app's container and, at the next launch, tells XSide (in its signed check-in, once the local network is allowed) that the previous run stopped while in use; an app open on screen says goodbye on its live connection when it leaves, so a connection that drops without it means the app vanished; either way XSide reads that app's newest crash report at once. For every app, with or without the module, XSide lists each connected device's crash reports every 2 minutes, every 15 seconds for 3 minutes after an install or an app's check-in, never while the device is being refreshed, and less often while the device can't answer (locked, out of reach); only the few new reports of its own apps are copied. A new crash posts a notification (once per crash report) that opens the crash window; *Settings > Notifications > Notify me when an app crashes* and the device's own notification switch turn it off. *Why does it crash?* stays in the app's ... menu.
- **iPhone Duo compatibility**, an install option per device (step 2 of the install window, the summary, and *Settings > My apps*): *Add iPhone Duo compatibility* lets an app built before SDK 27.1 use all of the iPhone Duo's screens, inner and outer, in Duo mode. XSide declares SDK 27.1 in the app's executable (with Xcode's `vtool`, keeping its minimum iOS) and its Info.plist, and, when the app has no scene manifest, adds one naming the app's own scene delegate, found in its executable. An app that has no scene support at all (no manifest, no scene delegate of its own) gets a small compatibility module of XSide's instead (independent of the XSide module), which adopts the app's window and passes it links, quick actions and the move to and from the background; the option then says so, with a stronger warning (the display and some behaviors may be imperfect), and the install step says the module was added; a crash in that module is named, with *Reinstall without Duo compatibility*. Highlighted on a Duo for an app not made for it (the preflight says so too), "not recommended" on other devices, greyed when the app already supports the Duo; whatever its state, the option keeps its full explanation, with one highlighted line saying why it's recommended or not. Off unless turned on, after a confirmation (the app wasn't made for it: glitches are possible). Works with or without the XSide module, is kept across refreshes, and never fails an install: if it can't be added, the app is installed without it and the window and the panel say so; the install shows its own step, *Adding iPhone Duo compatibility*, with how it went. Sometimes just relaunching the app is enough for it to adapt.
- **Simulate signed-out iCloud**, an install option per device (step 2 of the install window, the summary, and *Settings > My apps*): XSide gives no app iCloud (a free account can't have it, and XSide doesn't set it up with a paid team either), and an app that uses it often crashes at its first iCloud call. With the option, XSide adds a small library of its own (independent of the XSide module) that makes the app believe no iCloud account is signed in instead of crashing: CloudKit (no account; every request fails "not authenticated", operations finish), Core Data and SwiftData with iCloud and CKSyncEngine (they wait for an account), settings synced through iCloud (kept on the device) and iCloud Drive (seen as unavailable). Data stays on the device, nothing syncs; an app that requires iCloud to work usually launches, but may stay on its sign-in screen. XSide reads the app's entitlements at import: when they declare iCloud, the option is highlighted and the preflight warns that the app may crash; an app that only links CloudKit (many do without using it) gets no warning, the option just says it's useful if the app crashes because of iCloud; for an app that doesn't use iCloud, it says it isn't needed. Same with a free account or a paid team. Off unless turned on, kept across refreshes, its own install step (*Adding signed-out iCloud*); if it can't be added the app is installed without it and the window and the panel say so. When an app crashes in iCloud, the crash box, banner and window offer *Reinstall with signed-out iCloud*. Like the Duo option, it always shows its full explanation, with a highlighted line for how it stands for the app.
- **Compatibility fixes**: the iPhone Duo and signed-out iCloud options have their own section, apart from the other install options, in step 2 of the install window, its summary and *Settings > My apps* ("XSide changes the app so it works better on your device or with a free account").
- **Request a fix**: the crash window's button opens a GitHub request titled with the app's name and filled with the diagnosis (cause, library, iOS and XSide versions, which fixes were on), cleaned of anything personal (no bundle or team id, no device name); *Settings > Build & contribute* has a card for a request of your own (a fix for one app, or for an iOS service like iCloud).
- **A "Build & contribute" page in Settings**: make XSide yours (changes of your own with an AI agent, scripts with the `xside` command) and share it back if you want. Opens AGENTS.md and CONTRIBUTING.md on GitHub, copies a starter prompt for an agent, lists the real `xside` commands.
- **The XSide module in the apps: settings per device, kept in step between the Mac and the iPhone.** Each installation (app on a device) has its own XSide settings. A change made on the Mac or the iPhone reaches the other side at the next connection; field by field, the most recent change wins (a tie goes to the iPhone). Old state loads as before.
- **An "XSide Settings" page in the app's iOS Settings** (touch and hold the app's icon > *XSide Settings*, or *Settings > Apps > [app name] > XSide Settings*, behind one row; in English or French, translated by iOS into the app's own languages; XSide adds no language to the app): valid until, last refreshed, version, and the switches below. The footer says that choices apply at once on the device and that XSide on the Mac is told at the next connection.
- **A pill at launch** ("XSide: ...") says how many days the app stays valid, then goes away. On by default, per app.
- **A late alert**: if XSide couldn't refresh in time (less than the refresh threshold minus 6 hours left), the pill turns orange, then red under a day, with what to do and a Refresh button. When automatic refresh is off for the app, it says so with the expiry date instead.
- Per app, switches for **the card after a refresh**, **the reminder before expiry** (replaces the single global reminder switch), **automatic refresh**, and the **language of XSide's messages** (automatic, English, French). On the Mac, a single choice (*All*, *Essentials*, *None*, or *Custom*) summarizes the four switches.
- **Touch and hold the app's icon**: XSide Settings, Refresh now, Report a problem (localized), right from the install. They are written into the app after its own quick actions, in the places those leave (iOS shows 4); an app that sets its quick actions while running shows fewer of its own.
- **Refresh and pause from the iPhone.** XSide answers its apps on the local network (Bonjour `_xside._tcp`), over a channel signed with a secret per installation, nonces and a time window: refresh now, pause or resume automatic refreshes, and a check-in at each launch (and on return to the app) that reports the app's settings and last refresh and brings the Mac's changes. Turning *Automatic refresh* off or on in the app's iOS Settings tells XSide at once. iOS asks to allow the local network the first time; macOS may ask to allow incoming connections for XSide (explained in the app). The iPhone waits and retries up to 20 seconds. A refresh asked from the phone is limited in rate, and one the phone didn't hear back about is resolved by the check-in.
- **"Refresh at next launch"** in the app's iOS Settings: asks XSide for a refresh the next time the app opens.
- **The install window in three steps** (Devices, Install, XSide module in the app) with Next/Back and clickable steps; Install at the last one. *Settings > Installing > Review the options at each install* (on by default): off, an app already installed shows the full list of what will apply, with Edit.
- **Step 3 explains every option** with a one-line description and a preview (pill, late alert, card, notification), plus a highlighted box saying where to find the settings later on the iPhone, with the app's name: touch and hold its icon, or *Settings > Apps > YouTube > XSide Settings*. The box above the options says plainly when installing without XSide features helps (the app refuses to launch because it detects a change). Preflight warnings now show where Install is pressed.
- **Settings > My apps**: pick the device (a card with its full name, a menu when there are several), then one of its apps (icon, name, version, days left, a *Paused* badge) for the same options (the app's ... menu in the panel opens it on that app), applied at the app's next refresh or opening. For each device it says plainly where things stand: "App open on <device>: changes arrive live" (while the app holds its live connection, or, when it polls, until its next check-in is due: 15 seconds, 45 in Low Power Mode, plus a few; it changes by itself shortly after the app leaves the screen), "Changes will arrive the next time the app opens", "Not connected yet: open the app and allow the local network", "Not seen since ..."; what is pending, by name ("Automatic refresh: on — pending"); and "<device> received your settings (on ...)" once it confirmed them. Nothing is claimed active before the iPhone confirmed it.
- **Install without XSide features**, for apps that refuse to launch because they detect a change: for all apps (*Settings > XSide module in the apps*) or per app (step 3, and *Settings > My apps*), after a confirmation listing what's lost. XSide keeps refreshing them; the per-app choice wins over the default. Applies at each app's next refresh.
- The panel shows who paused an app's refreshes (this iPhone, this iPad or the Mac) and uses two-line subtitles.
- **The first-launch sheet explains before iOS asks.** It now has pages: *Installed with XSide*, then *Local network* (why: refresh or pause from the iPhone, settings kept in step with the Mac; what happens if you refuse) and *Notifications* (the reminder before expiry), each shown only when iOS will ask, with its prompt right after it. Nothing reaches the network before the *Local network* page was read, whatever the XSide messages are set to; an app installed earlier shows that page on its own before its first network access. Apps that use the local network themselves (e.g. to cast) can make iOS ask before that page: once iOS has shown a question over the app, XSide checks silently first, and skips the page when the access is already allowed, or shows a short page saying it was refused and where to turn it back on. The page names the app ("YouTube talks to XSide on your Mac…").
- **Settings sync feedback in the app, one pill per change that says what changed**: settings changed in iOS Settings are sent when the app opens, and one pill says which and that XSide on the Mac knows ("Reminder before expiry" turned off: XSide on your Mac knows), or that the Mac is unreachable and they go at the next connection. A change made on the Mac shows once, the same way ("automatic refresh turned back on from XSide on your Mac"; several are listed under "settings updated from your Mac"), and opens the app's page in iOS Settings; only "None" (every XSide message off) hides it, and turning messages off from the Mac is still said once. At launch, XSide is asked first, so the pill shows things as they are now, and the news replaces the plain validity line.
- **Live while the app is open**: while an app is on screen, it keeps a signed connection open to XSide, and a change made on the Mac (a setting, a pause or resume, from *My apps*, the panel or `xside`) is written to it the moment it's stored, so it shows in the app at once, in the usual pill. Every line XSide writes is signed for that app and that connection and numbered, and the app checks each one: nobody else on the network can send it settings or replay an old line. Only an app whose request is signed holds such a connection (one per app, a few per device), XSide renews it every 5 minutes, and the app closes it when it leaves the screen. When it can't be opened (an older XSide, the Mac away), the app checks in every 15 seconds (45 in Low Power Mode) as before. Never before the local network was allowed, and never in the background. On the Mac, the check-in that delivers a change made there is recorded at once, so *My apps* says it arrived; the Mac's log names the fields each answer changes, and the app logs what it adopted and shows (lines starting with "XSide:").
- **Pause one app for a while**: an app's ... menu in the panel has *Pause* > *For 2 hours*, *For 1 day* or *Until I resume* (the former *Stop refreshing*). The row shows "Paused until ..." with the paused look and *Resume*; the app's own pause ends by itself, and the app on the iPhone is told like any pause from the Mac, with when it resumes.
- **A *My apps* tile at the top of the panel**, beside Install, Refresh all and Pause, opens *Settings > My apps* directly.
- **New `xside` commands**: `xside apps` and `xside devices` (`--json` too); `xside settings <app>` shows an app's XSide module settings, and `xside settings <app> reminder=off level=essentials…` changes them as *Settings > My apps* does (`--device` for one device); `xside pause <app> [2h|30m|1d]` and `xside resume <app>` for one app; `xside uninstall <app>` (asks first unless `--yes`); `xside logs [-f]`; `xside report` writes the logs archive and prints its path. Apps are named by name or bundle id, any case; when several match, `xside` lists them. `xside` waits for a long uninstall or report as long as it takes, saying it's still working; exit status 2 means the outcome isn't known yet (see the panel).

### Changed

- The panel's app rows no longer show a refresh button on hover: *Refresh now* is in the row's ... menu (and its right-click menu).
- The app's SDK is read from its executable at import. The "built for an older iOS" preflight note no longer shows: outside an iPhone Duo the layout difference it promised mostly isn't there, and on a Duo the iPhone Duo note says what matters (and only offers the option when the app can take it).
- **Settings reorganized** into General, Refreshing, Installing, XSide module in the apps (defaults for new installs), My apps, Notifications, Xcode and signing, Updates, Reports & Logs, Build & contribute, About.
- XSide's switches use the brand gradient and respond to the keyboard (focus ring, Space).
- The install window is wider, step 3 in two columns: the steps fit without scrolling (it still scrolls on a small screen).
- The *Messages XSide* and *Language* choices use XSide's own popup (brand chevron box) instead of the grey system one.
- Resuming an app's refreshes from the panel keeps the panel open; after a row's confirmation (stop refreshing, uninstall, remove from the list) the panel opens again.
- The install step "Adding XSide features" is "Injecting the XSide module", and says "skipped (installed as is)" when it was.
- **Refresh now from the iPhone says what happens next**: "refresh asked of your Mac, the app will close when it's done (about 1 min), open it again then", until the outcome (done, refused and why, or the Mac unreachable and what to do).
- XSide Settings (touch and hold the icon, or a pill) opens the app's page in iOS Settings, where XSide's row is (iOS gives apps no way to open a page under theirs).
- In the app, XSide's texts wrap instead of being cut (the sheet's "These details stay in Settings > ..." line, long pills). With every XSide message off, no pill shows on its own; the answers to a Refresh you asked for (and to a pill's button) still show.
- The answer to a Refresh asked from the iPhone that arrives while you're in another app shows when you come back (within 10 minutes). "XSide on your Mac doesn't know this app" also suggests checking the date and time.
- *Settings > My apps* says when an app was installed by an earlier XSide (reachable after its next refresh), and an app whose XSide module couldn't be added counts as installed without XSide features.
- XSide's Bonjour service is published as "XSide" rather than under the Mac's name.
- **Windows sized to what they show**: each Settings page makes the window as tall as it needs (within the screen), so pages no longer scroll at the default text size; the install window gives its steps all the room the screen leaves.
- While every refresh is paused from the panel, each app row looks paused too ("all refreshes paused"), and comes back on resume.
- *Settings > Build & contribute* installs the `xside` command right from its terminal card (or says where it is), as *General* does.
- The install progress matches what really happens: the module step shows as skipped (not ticked) for an app installed as is, the install step says when the app is deleted from the device first, and the list under the module step tells what is written into the app now and what the module does once the app opens.
- "XSide in the apps" is now **"XSide module in the apps"** (Settings page, install step 3, What's New).
- *Settings > My apps* starts with the device (a segmented control, or a menu with more than three), then that device's apps, then the app's settings: each app on a device has its own settings. No more device tabs on the right.
- In the app, pills, the first-launch sheet and the card wrap their text and grow instead of being cut or touching the screen's edges; a pill's button sits under its text.
- Existing apps get their per-app values from today's global settings (the global reminder switch becomes each app's reminder; the others start on).
- The install window lists what *Injecting the XSide module* does from the start of the install, greyed until that step runs, then ticked.

## [1.0.6-beta] - 2026-11-06

### Added
- **Notifications per device** (the device's … menu in the panel): turn them off for an iPhone you manage for someone else; its apps are still refreshed, without any notification on this Mac (the reminder the app shows on the phone itself stays).
- `xside pause [2h|30m|1d]` and `xside resume` pause and resume automatic refreshes from the Terminal; `xside status` says while they're paused.
- Updates can be checked every hour; XSide also checks when it starts and after each app refresh (at most every 10 minutes).
- The install window warns when an app wasn't built for the device's iOS (it may open in compatibility mode, e.g. a YouTube built with the iOS 26 SDK on an iOS 27 iPhone), and when it's older than the version already installed.
- Each app in the panel shows its installed version.
- Installing another version of an app over the one on the device: its card says "Updated by XSide" (or "Older version installed by XSide"), with the new and the previous version, instead of "Refreshed by XSide".

### Changed
- The XSide sheet in apps follows the reader's text size (Dynamic Type) and scrolls when it doesn't fit (landscape, large text).
- "Last refreshed" in the app's iOS Settings section is the time it was signed, not the profile's creation.

### Fixed
- **Apps that still carry an old 32-bit version are no longer refused as encrypted.** XSide only looks at the part of the app that your iPhone or iPad can run, and removes the old 32-bit part when it installs the app.
- `xside pause` refuses a duration past a year instead of crashing on a huge number, and a garbled pause request is refused instead of pausing until resumed.
- `xside status` counts the next refresh with the chosen days before expiry (it assumed 2), says when refreshes are paused, and `--json` has `pausedUntil`.
- Version checks read the leading digits of each part ("1.10a" is newer than "1.9", "21.37.04" equals "21.37.4"), and the "older version" warning only compares the same copy of an app.
- An update found again after "Remind me later" no longer notifies more than once a day.

## [1.0.5-beta] - 2026-11-05

### Added
- **XSide in your apps.** Every app XSide installs says where it comes from and until when it works: after an install, a sheet with the XSide logo, the expiry date and the days left (in its own window, so the app's screens can't cover or close it); after a refresh, a smaller card at the bottom, closed with OK. A new install step, "Adding XSide features", lists what's added.
- **A reminder on the device**, the day before an app expires, with XSide's logo, sent by the app itself. If the app never asked for notifications, the permission is asked once, when the install sheet is closed, and the sheet says why beforehand.
- **An "Installed with XSide" section in the app's iOS Settings page** (*Settings > Apps > the app*): valid until, last refreshed, and XSide's address. Rewritten at each refresh; the app's own settings stay as they were. The install sheet says where to find it.
- **The app opens on the device after an install**, which also tells whether the device trusts the developer. If not, XSide opens *Settings > General > VPN & Device Management* on the device itself, and the guide says so (with a button to open it again). If it does, no guide. When the device can't tell (locked), the guide shows on a first install, after the last XSide app was deleted from the device, or with a new certificate.
- **Apps deleted from the device stay deleted.** XSide notices (before a refresh, every 10 minutes on each reachable device, and when the panel opens), removes them from its list, drops their reminder, and says so in a notification. A refresh no longer puts them back.
- **Choose when apps refresh** (*Settings > General > Automatic refreshes*): 1, 2 (default) or 3 days before they expire; pause (1 hour, until tomorrow morning, until resumed), also from a new **Pause** tile in the panel, which says while refreshes are paused; only on power adapter; a preferred time (night or evening). An app expiring within 12 hours is refreshed anyway, and refreshes you start yourself are never held back.
- **Report a problem** (*Settings > Reports & Logs*, and the bug button in the panel): opens XSide's bug form on GitHub, filled in with the versions, the devices, XSide's state and the last log lines, and saves the full log archive on the Desktop to drag into it. The issue doesn't name your apps (`<app-1>`…); device names, serial numbers, account and team are masked in both, and nothing is sent until you submit.
- *Settings > General > Installs and devices*: open the app after an install and open the Trust page (both defaults, changeable in each install's Options), notice deleted apps, refresh new devices over Wi-Fi or not. *Settings > Notifications*: the reminder on the device, the notification when a deleted app leaves the list.
- The install window's device tiles say what stops an install there: "Developer Mode off", or "Unlock it" after an attempt failed on a locked device.

### Changed
- The trust guide shows a single step without a number, and no longer starts with "Then".
- The shared keychain option says to turn it on when signing in fails ("can't sign in", "app not verified").
- *Settings > Logs* is now *Reports & Logs*, with *Report a problem* first.

### Fixed
- Reminders in tweaked apps that pretend to be another app (e.g. a modded YouTube reporting "com.google.ios.youtube" for Google sign-in): iOS refused them notifications without asking. XSide now asks with the app's real identity, and an app name with special characters ("YouTube +") gets a plain internal name.
- A device with Developer Mode off: the install window says so and how to turn it on, and doesn't start an install that can only fail. If it fails anyway, the message says Developer Mode is off instead of "Couldn't create the provisioning profile".
- A locked device that Xcode has to prepare for development: the message says to unlock it, instead of "Couldn't create the provisioning profile".
- A device out of reach during an uninstall (CoreDevice error 1011) is reported as unreachable, not as a failed uninstall.

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

[1.0.6-beta]: https://github.com/Antholife/xside/compare/v1.0.5-beta...v1.0.6-beta
[1.0.5-beta]: https://github.com/Antholife/xside/compare/v1.0.4-beta...v1.0.5-beta
[1.0.4-beta]: https://github.com/Antholife/xside/compare/v1.0.3-beta...v1.0.4-beta
[1.0.3-beta]: https://github.com/Antholife/xside/compare/v1.0.2-beta...v1.0.3-beta
[1.0.2-beta]: https://github.com/Antholife/xside/compare/v1.0.1-beta...v1.0.2-beta
[1.0.1-beta]: https://github.com/Antholife/xside/compare/v1.0.0-beta...v1.0.1-beta
[1.0.0-beta]: https://github.com/Antholife/xside/releases/tag/v1.0.0-beta
