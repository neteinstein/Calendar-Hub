<div align="center">

<img src="docs/icon.png" width="128" height="128" alt="Calendar Sync app icon">

# Calendar Sync

**Your secondary calendars' meetings, in your main calendar.**

A small Mac menu bar app that copies the meetings from your other calendars into the one your colleagues book you through, so nobody books you over a meeting they can't see. It also keeps your day in view: the next meeting a click away, a nudge when it starts, and the tasks to prepare it.

[![Version 2.0.4](https://img.shields.io/badge/version-2.0.4-2563EB)](Support/Info.plist)
[![Build](https://github.com/neteinstein/Calendar-Sync/actions/workflows/build.yml/badge.svg)](https://github.com/neteinstein/Calendar-Sync/actions/workflows/build.yml)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-111?logo=apple&logoColor=white)
[![Homebrew tap](https://img.shields.io/badge/homebrew-neteinstein%2Ftap-FBB040?logo=homebrew&logoColor=white)](https://github.com/neteinstein/homebrew-tap)
[![License: Sustainable Use 1.0](https://img.shields.io/badge/license-Sustainable%20Use%201.0-8B5CF6)](LICENSE.md)

<a href="https://github.com/neteinstein/Calendar-Sync/raw/main/docs/calendar-sync.mp4">
  <img src="docs/demo.webp" width="860" alt="Calendar Sync demo: meetings from a secondary calendar are copied into the main calendar as [Calendar A] meeting name, with the Teams link">
</a>

<sub>▶ <a href="https://github.com/neteinstein/Calendar-Sync/raw/main/docs/calendar-sync.mp4">Watch with sound</a> · 21 seconds</sub>

</div>

---

## Why

Booked solid in another calendar. Wide open in your main calendar.

When your meetings live in a secondary calendar (another company's account, a second job, a personal calendar), your main calendar says you're free all day. Calendar Sync copies each meeting across as **`[Calendar A] Sprint planning`**, with its join link, and keeps the copy right when the meeting moves or is cancelled.

## A look around

### The menu

<table>
<tr>
<td width="50%" valign="top">
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/menu-month-dark.webp">
  <img src="docs/screenshots/menu-month-light.webp" alt="The menu's month view: the next meeting with a Join button above a month grid with a dot per calendar">
</picture>
<b>Month.</b> The next meeting with a countdown and <b>Join</b>, and the month with a dot for each calendar that has meetings that day. Click a day for its meetings.
</td>
<td width="50%" valign="top">
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/menu-list-dark.webp">
  <img src="docs/screenshots/menu-list-light.webp" alt="The menu's list view: today's meetings with a red line at the current time">
</picture>
<b>List.</b> Opens at today, with a line at the current time, the finished meetings folded away, and <b>Join</b> as a meeting comes up.
</td>
</tr>
<tr>
<td width="50%" valign="top">
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/menu-tasks-dark.webp">
  <img src="docs/screenshots/menu-tasks-light.webp" alt="The menu's Tasks view: today's tasks, two of them to prepare Design review, each with its next nudge">
</picture>
<b>Tasks.</b> Tasks and reminders, kept in Reminders. Tie one to a meeting to prepare it, and set nudges to get it done. They move with the meeting, show on its alert, and on their day in Month and List.
</td>
<td width="50%" valign="top">
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/menu-stats-dark.webp">
  <img src="docs/screenshots/menu-stats-light.webp" alt="Meeting Stats: hours in meetings per day, a chart of the last two weeks, insights and the year pictured as a walk from Lisbon to Paris">
</picture>
<b>Stats.</b> Where your week goes: hours in meetings, the last two weeks, your busiest day, the free time left today, and a year of it pictured as a trip.
</td>
</tr>
</table>

### Task notes

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/task-notes-dark.webp">
  <img src="docs/screenshots/task-notes-light.webp" width="560" alt="A task's notes window: Read the design doc, for Design review, with notes in Markdown: a heading, a list, a checklist, a quote and a link">
</picture>

Open a task's notes in a window of their own: Markdown, formatted as you type, with buttons for headings, bold, lists, checklists and links. They're saved in the reminder's notes, so Reminders has them too.

### When a meeting starts

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/alert-dark.webp">
  <img src="docs/screenshots/alert-light.webp" width="860" alt="The full-screen meeting alert: Design review starts in 0:59, with two tasks to prepare it, Join call, Go to Room 2.04, Ignore and Remind me in 1 minute">
</picture>

The screen blurs and a card counts down to the start, with the meeting's open tasks **to prepare**, and **Join call** (⏎), **Go to** the room, **Ignore** (esc) or **Remind me in 1 minute**. Any other key, or a click anywhere but the buttons, ignores it too. It's on unless you turn it off, and each meeting alerts once.

### In the menu bar

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/menu-bar-dark.webp">
  <img src="docs/screenshots/menu-bar-light.webp" width="520" alt="The menu bar item showing the date, and showing Design review · 13m">
</picture>

Today's date, or, if you like, the next meeting and the minutes left when it's 15 minutes away.

### Settings

<table>
<tr>
<td width="50%" valign="top">
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/settings-calendars-dark.webp">
  <img src="docs/screenshots/settings-calendars-light.webp" alt="Settings, Secondary Calendars: each calendar with when it last synced and how many copies it has">
</picture>
</td>
<td width="50%" valign="top">
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/settings-menuBar-dark.webp">
  <img src="docs/screenshots/settings-menuBar-light.webp" alt="Settings, Menu bar: the menu calendar, the next meeting in the menu bar and Meeting Stats">
</picture>
</td>
</tr>
</table>

<details>
<summary><b>The other panes</b></summary>
<br>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/settings-general-dark.webp">
  <img src="docs/screenshots/settings-general-light.webp" width="640" alt="Settings, General: main calendar, how far ahead and how often to sync, what's copied">
</picture>
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/settings-twoWaySync-dark.webp">
  <img src="docs/screenshots/settings-twoWaySync-light.webp" width="640" alt="Settings, Two way sync: show the main calendar as Busy in the secondary calendars">
</picture>
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/settings-alerts-dark.webp">
  <img src="docs/screenshots/settings-alerts-light.webp" width="640" alt="Settings, Meeting alerts: the full-screen alert and how early it shows">
</picture>
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/settings-tasks-dark.webp">
  <img src="docs/screenshots/settings-tasks-light.webp" width="640" alt="Settings, Tasks: the Tasks view in the menu, the Reminders list tasks are kept in, and the nudges new tasks get">
</picture>
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/settings-about-dark.webp">
  <img src="docs/screenshots/settings-about-light.webp" width="640" alt="Settings, About: version, update check, feedback and donations">
</picture>

</details>

<sub>Screenshots show sample calendars.</sub>

## What it does

- **Copies your meetings across**, titled by the calendar they came from, with the Teams, Zoom, Google Meet or Webex link, so **Join** works from your main calendar.
- **Keeps the copies right:** moved meetings move, cancelled ones disappear, and recurring meetings just work.
- **Reads calendars your Mac can't add:** sign in to **Outlook on the web** once in the app, or subscribe to a published **.ics** link.
- **Hides meeting names** for a calendar if you'd rather: its copies read `[Calendar A] Busy`, link included.
- **Syncs both ways**, if you like: your main calendar shows as **Busy** in your secondary calendars, with nothing else in it, not even alerts, so a meeting doesn't notify you twice.
- **Keeps your tasks** in a Tasks view and on their day in Month and List, as reminders in Reminders, so they're on your iPhone too and stay if you remove the app. A task can be for a meeting, moves with it, nudges you when you say, and has notes in Markdown.
- **Stays out of the way:** it never copies attendees, so no invites go out, never copies its own copies back, and leaves copies alone when a calendar can't be read.

## Install

With [Homebrew](https://brew.sh/):

```bash
brew install neteinstein/tap/calendar-sync
```

It needs macOS 14 or later and the Xcode command line tools: Homebrew builds the app on your Mac.

### Run it

Once:

```bash
open "$(brew --prefix)/opt/calendar-sync/Calendar Sync.app"
```

Or every time you log in:

```bash
brew services start neteinstein/tap/calendar-sync
```

The first time it runs, it links itself into your Applications folder, so you can also open it from Finder or the Dock.

### Set it up

1. Allow calendar access when macOS asks.
2. Open **Settings…** from the menu bar icon, and in **General** choose your main calendar.
3. In **Secondary Calendars**, add the calendars to copy from.

That's it. It syncs every 15 minutes, and calendars in Calendar.app within seconds of a change.

### Update

```bash
brew update && brew upgrade calendar-sync
```

Then restart it with `brew services restart calendar-sync`, or quit it and open it again. Or let the app do it: it checks for a new version once a day, and when there is one, a blue **update** button appears next to **Sync now** in the menu. Click it and Terminal runs these commands and restarts the app. More in [Install and update](docs/install.md), including building from source.

## Feedback and issues

Found a bug, or have an idea? [Open an issue](https://github.com/neteinstein/Calendar-Sync/issues). Settings › About › **Send feedback or report a bug** takes you there too.

## Learn more

- [Install and update](docs/install.md): Homebrew in detail, opening at login, building from source, a separate admin account, and a missing menu bar icon.
- [How it works](docs/how-it-works.md): how copies are made and matched, two way sync, the menu, the alert, tasks and Meeting Stats in detail, and known limits.
- [Outlook on the web](docs/outlook-on-the-web.md): how the app reads (and can write to) a browser-only Outlook calendar, and what to check first.
- [Development](docs/development.md): tests, how the code is laid out, screenshots and releases.

## License

Calendar Sync is source-available under the [Sustainable Use License 1.0](LICENSE.md) (SPDX `SUL-1.0`). You can use and change it for free, for personal use or at work, **including commercially** for your own business. You can share it, with or without your changes, as long as you do so for free and for noncommercial purposes. Selling it, building a product or service from it, or including it in one needs a separate licence from the author.

Copyright (c) 2026 Pedro Vicente (https://github.com/neteinstein)

<div align="center">
<br>
<sub>Demo video made with <a href="https://github.com/latent-spaces/brag">/brag</a>.</sub>
</div>
