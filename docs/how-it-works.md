# How it works

[← Back to the README](../README.md)

```mermaid
flowchart LR
    A["Secondary calendar<br/>in Calendar.app"] --> S
    B[".ics calendar link<br/>(subscribed)"] --> S
    C["Outlook on the web<br/>(sign in once)"] --> S
    S{{"Calendar Sync<br/>plan: add · update · remove"}} --> M["Main calendar<br/>[Calendar A] Sprint planning ▶ Join"]
    M -. "Two way sync: Busy, no details" .-> A
    M -. "Two way sync (experimental)" .-> C
```

## Copies

- **Named by its calendar.** Each copy is titled **`[Calendar name] Meeting name`**, e.g. `[Calendar A] Sprint planning`. For calendars in Calendar.app it uses the calendar's own name and picks up renames. With **Hide meeting names** on for a calendar, its copies are titled `[Calendar A] Busy` instead, and the meeting link still comes along.
- **Meeting link included.** Teams, Zoom, Google Meet and Webex links are copied onto the event and shown first in its notes, so **Join** works straight from your main calendar.
- **Matched by a hidden tag.** Every copy ends its notes with a tag like `calsync:v1:<source id>:<occurrence id>`. The app uses it to recognise its own copies and match them to their originals, not by title and time. So a moved meeting gets updated instead of duplicated, a cancelled one is removed, and recurring meetings just work.
- **Safe by design.** It never copies attendees, so no invites go out. It never copies its own copies back, so two-way setups don't loop. If a calendar can't be read, its copies are left alone.
- **What's copied.** You can **skip meetings you declined**, **skip all-day events** and **skip out-of-office events** (on by default). Per secondary calendar, copies can also get the meeting's **location and description**.

It syncs **every 15 minutes** by default; set any interval from 1 minute to 24 hours, and give a secondary calendar **its own interval** when it should sync more or less often than the rest (say, Outlook on the web hourly). Calendar.app calendars also sync about 10 seconds after a change. Settings has a **Preview** that shows what the next sync would change before it changes anything.

## Secondary calendars it can read

| Secondary calendar | How to add it |
|---|---|
| **Added to Calendar.app** (Exchange, Google, iCloud, …) | **Add secondary calendar › From Calendar.app** |
| **Browser only, with a published link** | **Add secondary calendar › Calendar link (.ics)**. Calendar.app subscribes to the link, then you pick it like any other calendar. |
| **Browser only: Outlook / Microsoft 365** | **Add secondary calendar › Outlook on the web**. Sign in once in the app's own window (MFA included, also with a USB security key). Each sync reloads Outlook's week view in the background, reads the meetings it loads, then loads each meeting in full for its join link and details. *Experimental.* See [Outlook on the web](outlook-on-the-web.md). |

## Two way sync

Optional, in the **Two way sync** pane. Your main calendar's events are added to your secondary calendars as plain **Busy** events — or **Out of office**, your pick per calendar — with the time and nothing else: no title, link, location, attendees or alerts, so a meeting doesn't notify you twice. Their description is just “Busy”, so you can tell what was added automatically, and nothing in them names the app. Copies of a secondary calendar's own meetings are skipped, and meetings copied from the other secondary calendars do show, so each one sees the time the others have booked. It works with secondary calendars you can edit in Calendar.app and, if you also turn on **Also sync Outlook on the web calendars** (experimental), with Outlook on the web calendars. `.ics` link calendars are read-only.

The Busy events carry no tag. The app recognises them by their title (**Busy** or **Out of office**), their description (just “Busy”), having no attendees and not repeating, and matches them to your main calendar by time. So in a secondary calendar that two way sync writes to, an event you make yourself that looks exactly like that is treated as one of them.

## The menu

- **Up next.** The menu leads with the next meeting today, or the one under way, with a countdown and a **Join** button.
- **Month view.** Turn on **Show a calendar in the menu** and the icon gains **today's date** (add the **week day** next to it if you like). The month shows a dot for each calendar with meetings that day; click a day for its events. Start the week on **Sunday or Monday**, and hide **weekends** if you like.
- **List view.** A scrolling list of your main calendar's events. It opens at today, with a line at the current time, today's finished meetings folded into one row, and each day's header kept in view while you scroll. Copies show the meeting's own name, with the calendar it came from under it, and a **Join** button appears from 15 minutes before a meeting.
- **Colors.** The lists tint each event with the **color of the calendar it came from**, shade **all-day events**, and group each day's **morning** and **afternoon** into colored blocks. Each of these can be turned off.
- **Status.** A pill says when the last sync ran. Anything that went wrong shows as a card with its fix, like **Open Outlook** for a calendar that signed you out; click the pill's count to see it in Settings.
- **Next meeting in the menu bar.** Turn on **Show the next meeting in the menu bar** and, from 15 minutes before a meeting until it ends, the icon shows its name and the minutes left, like `Design review · 12m`.

## The meeting alert

The **full-screen alert** (on unless you turn it off) blurs the screen when a main-calendar meeting begins, or up to 15 minutes before, and counts down to the start. Its buttons: **Join call** (⏎), **Go to** the room, **Ignore** (esc), or **Remind me in 1 minute**. Any other key, or a click anywhere but the buttons, ignores it too. Meetings copied from secondary calendars alert too, join link and calendar name included. Each meeting alerts once; a meeting already under way (say, after the Mac wakes) alerts until it ends.

## Meeting Stats

Turn on **Meeting Stats** and the menu gains a **Stats** view: hours in meetings **yesterday, today and tomorrow**, a chart of the **last two weeks**, **last week** (and how it compares with the week before) and **last month**, your **average per working day**, your **busiest weekday**, how many meetings ran **back to back**, the **longest free block** left today and when it is, how much of this week's working hours you're **out of office**, and a **prediction for the year**, pictured as a trip, like walking from Lisbon to Paris.

Only timed meetings in your main calendar count: all-day, declined and out-of-office events don't. Overlapping meetings count once, with the total counting overlap next to it, like "20 hours (25 counting overlap)". Out of office counts the time it covers within working hours, Monday to Friday. Working hours are 9:00 to 17:00 unless you set your own in Settings.

## Updates

Settings' **About** pane shows the app **version** and checks GitHub once a day for a newer one (the newest release, or the version on `main` while there are no releases). When there is one, a warning appears with an **Update** button that shows the commands to run.

## Known limits

- Calendar.app refreshes accounts every few minutes, so changes made in a secondary calendar show up with that delay.
- If you remove a secondary calendar from the app, the copies already made from it stay in your calendar, and the Busy events two way sync added to it stay in the secondary calendar. Delete them in Calendar if you no longer want them. To have the app take the Busy events back, turn off **Show my main calendar here** (or **Sync both ways**) and let it sync before removing the calendar.
