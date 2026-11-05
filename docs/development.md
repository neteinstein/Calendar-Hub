# Development

[← Back to the README](../README.md)

```bash
swift test
```

The tests cover the sync rules: titles, meeting links, details, moves, deletes, filters, no loops, per-calendar intervals, the Outlook data parser and the Outlook Busy-event requests, the menu's date and text helpers, and tasks: nudge times, sections and following a moved event, and the notes' Markdown styling and editing. They run on Linux too. CI builds the app and runs the tests on macOS for every push.

To build and run the app, see [From source](install.md#from-source).

| Folder | What's in it |
|---|---|
| [`Sources/CalendarSyncCore`](../Sources/CalendarSyncCore) | Platform-independent rules: `SyncPlanner` (what to add, update and remove), `SyncSchedule` (which calendars are due), `CopyFormatter` (titles and notes), `MeetingLink`, `CopyMarker`, `HTMLText`, `MenuCalendar` and `MeetingStats` (the menu's dates, countdowns and stats), `Tasks` (tasks, nudges, their link to an event, and `TaskPlanner`, which sorts them and moves them with their event), `Markdown` (how the notes window styles and edits Markdown), `OutlookWebParser` and `OutlookWebWriter` (the requests that write Busy events to Outlook on the web) |
| [`Sources/CalendarSync`](../Sources/CalendarSync) | The macOS app: `EventKitBridge` (Calendar.app), `OutlookWebSource` (built-in Outlook browser), `SyncController` (scheduling), `EventAlertController` (the full-screen alert), `TaskStore` (tasks in Reminders), `TaskNotesWindow` and `MarkdownEditor` (a task's notes), `DemoMode` (sample calendars and screenshots) and the SwiftUI views |
| [`Tests`](../Tests) | Unit tests for the core |
| [`scripts/build-app.sh`](../scripts/build-app.sh) | Builds and signs `Calendar Sync.app` |
| [`scripts/screenshots.sh`](../scripts/screenshots.sh) | Renders the README's screenshots |

## Screenshots

```bash
scripts/screenshots.sh
```

Renders `docs/screenshots/*.webp`: the menu (Month, List, Tasks and Stats), the meeting alert, a task's notes window, the menu bar item and each Settings pane, in light and dark. The app draws them itself, with sample calendars (Work, Calendar A and Client X) and sample tasks in place of yours, so nothing from your own calendars ends up in them, and it runs next to a copy you already have open. Today's sample meetings sit around the current time, so run it during the day. It needs `cwebp` (`brew install webp`). Run it after changing how the menu, the alert or Settings look, and commit the new images.

To try the app with the sample calendars, start it with `CALENDAR_SYNC_DEMO=1`:

```bash
open -n --env CALENDAR_SYNC_DEMO=1 "build/Calendar Sync.app"
```

It reads nothing from Calendar.app or Reminders, writes nothing, keeps its settings apart from yours and shows no alerts.

## Releases

Every change that lands on `main` is a new version, and Homebrew users get it once the tap serves it. [AGENTS.md](../AGENTS.md) has the steps: the version bump, the README badge, and the PR on [neteinstein/homebrew-tap](https://github.com/neteinstein/homebrew-tap).
