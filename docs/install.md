# Install and update

[← Back to the README](../README.md)

You need **macOS 14 or later**. Homebrew and source builds also need **Xcode 15+** (the command line tools are enough); the download doesn't.

## Download

Every release has **Calendar-Hub.dmg** attached, built for Apple silicon and Intel. [Install Calendar Hub](download.md) is the step-by-step guide, with pictures, for installing, allowing and updating it.

The disk image is ad-hoc signed, not signed by Apple, so macOS blocks it the first time until it's allowed with **Open Anyway** in System Settings › Privacy & Security, and again after each update. The app updates by downloading the new disk image: its **update** button opens the [latest one](https://github.com/neteinstein/Calendar-Hub/releases/latest/download/Calendar-Hub.dmg).

## With Homebrew

```bash
brew install neteinstein/tap/calendar-hub
```

The formula lives in the [neteinstein/homebrew-tap](https://github.com/neteinstein/homebrew-tap) tap and builds the app from source on your Mac (that's why it needs the Xcode command line tools), so there's nothing to sign or notarize. `brew install --HEAD neteinstein/tap/calendar-hub` builds the latest `main` instead of the pinned version.

To run it once:

```bash
open "$(brew --prefix)/opt/calendar-hub/Calendar Hub.app"
```

- **Updating:** `brew update && brew upgrade calendar-hub`. Or click the blue **update** button that appears next to **Sync now** in the menu when a newer version is out (the app checks once a day): Terminal opens, runs these commands and restarts the app. Settings also warns you, and its **Update** button shows these commands. If the app is running, it keeps running the old version until the new one starts, and `brew upgrade` prints how: `brew services restart calendar-hub` if you started it with `brew services`, otherwise `open "$(brew --prefix)/opt/calendar-hub/Calendar Hub.app"`, or open it from your Applications folder. Either way the new version has the old copy quit and takes its place, however the old one was started.
- **Open at login:** run `brew services start calendar-hub` (the full name, `brew services start neteinstein/tap/calendar-hub`, works too) and leave **Open at login** in Settings off. Only one copy runs at a time, so a second login item would just start and quit (a copy that starts takes over only from an older version). The service runs the app from Homebrew's `opt` path, so it keeps starting the newest version after upgrades. `brew upgrade` doesn't restart it: run `brew services restart calendar-hub` for that.
- **In your Applications folder:** the first time it runs from Homebrew, the app puts a link to itself in `~/Applications`, unless `/Applications` already has one. Homebrew can't do that at install time, and your desktop account may not be allowed to write to `/Applications`, but it always owns `~/Applications`. The link goes through Homebrew's `opt` path, so it opens the newest version after upgrades. Finder and the Dock treat the link as the app; Spotlight and Launchpad don't list linked apps. Remove the link and it stays removed. Want it in `/Applications` instead? From an account that can write there, run `ln -s "$(brew --prefix)/opt/calendar-hub/Calendar Hub.app" /Applications/`. `brew uninstall` leaves the link behind: remove it with `rm ~/Applications/"Calendar Hub.app"` (or `/Applications/"Calendar Hub.app"`).
- **Homebrew in a separate admin account:** install and upgrade from the admin account as usual, but run `brew services` from the account you log in to the desktop with. The admin account has no desktop session to start the app in, so there it fails with `Domain does not support specified action`. If your own account then refuses to load the formula from an untrusted tap, run `brew trust --formula neteinstein/tap/calendar-hub` from it first. Don't start the app by hand from the admin account either (the hint `brew services` prints after a failure suggests it): that copy runs in the admin account, not in your desktop session, so it logs `Connection interrupted` errors and keeps running until you stop it with Ctrl-C or `pkill CalendarHub`.
- Upgrades are ad-hoc signed builds, so macOS asks for calendar access (and Reminders access, once you open Tasks) again after each one. Your settings and tasks are kept.

### Coming from Calendar Sync

The app was called Calendar Sync, formula `calendar-sync`, up to 2.0.19. `brew update` tells Homebrew about the rename, and `brew upgrade` (or the app's **update** button) installs Calendar Hub in its place. The first time Calendar Hub runs, it has a running Calendar Sync quit and brings across its settings, tasks and Outlook sign-in. It replaces the `~/Applications` link with one named Calendar Hub. As a new app, it asks for calendar and Reminders access again. Two things don't move by themselves:

- **`brew services`:** Homebrew doesn't move the old service. Start the new one and remove the old:

  ```bash
  brew services start calendar-hub
  launchctl bootout gui/$(id -u)/homebrew.mxcl.calendar-sync
  rm ~/Library/LaunchAgents/homebrew.mxcl.calendar-sync.plist
  ```

- **Open at login** in Settings: switch it on again if you used it.

## From source

```bash
git clone https://github.com/neteinstein/Calendar-Hub
cd Calendar-Hub
scripts/build-app.sh
open "build/Calendar Hub.app"
```

To update later: quit the app, then `git pull && scripts/build-app.sh` and reopen it. While the app is still in the clone's `build` folder, the menu's **update** button does that for you in Terminal. Local builds are ad-hoc signed, so macOS asks for calendar access (and Reminders access, for Tasks) again after each rebuild.

## First run

Allow calendar access on first launch. Then open **Settings…** from the menu bar icon and go through the panes in its sidebar:

1. **General:** choose your **main calendar** (the one meetings are copied into), how many days ahead, and how often to sync.
2. **Secondary Calendars:** add each secondary calendar. For Outlook on the web, also give it a calendar name; its meeting names are hidden from the start. Optionally turn on **Copy location and description** or **Use its own sync interval**, or turn off **Copy the meeting link** or **Copy meetings I haven't accepted**. Each calendar shows when it was last read and how many copies it has, or what went wrong and how to fix it.
3. **Two way sync:** turn on **Sync both ways** to show your main calendar as **Busy** in your secondary calendars, so they all show the same booked time. Turning it on includes every secondary calendar you can edit; turn off **Show my main calendar here** for any that shouldn't, or pick **Out of office** instead of **Busy**. For Outlook on the web calendars, also turn on **Also sync Outlook on the web calendars** (experimental).
4. **Meeting alerts** and **Menu bar:** the **full-screen alert** when each meeting starts, which is on unless you turn it off, the menu's month calendar and event list, also on by default, and the next meeting in the menu bar. **Tasks**, **World Clocks** and **Meeting Stats** each have their own pane; with Tasks on, Calendar Hub asks for Reminders right after Calendars.
5. **Preview:** see what a sync would change, then let it run.

## No icon in the menu bar?

If the icon is hidden, in System Settings › Menu Bar or by ⌘-dragging it out of the menu bar, Calendar Hub keeps running and syncing without it. Open the app again to bring the icon back. If it disappears again, turn Calendar Hub back on under **Allow in the Menu Bar** in System Settings › Menu Bar.
