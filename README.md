# SchoolSync

An iPhone app that pulls school events from multiple sources into one unified
calendar per kid, synced into the iOS Calendar app.

Built for a two-kid, two-school household: each kid can have a different
school, each school can publish events a different way, and everything ends
up merged in one place.

## How it works

Three ingestion paths, all landing in the same local store:

1. **ICS feed subscription** — if a school publishes a calendar feed
   (`.ics` URL), the app fetches and parses it directly. Most reliable path;
   check your school's site for "subscribe to calendar" / "export" first.
2. **Website scraping** — for schools with no feed, the app scrapes their
   calendar page using per-school CSS selectors you configure (via SwiftSoup).
   This is inherently fragile: it breaks whenever the school redesigns its
   site, and needs real selectors filled in per school (see below).
3. **Email forwarding (Share Extension)** — for one-off announcements that
   only arrive by email, forward/share the email from Mail into SchoolSync.
   The share extension scans the text for dates (`NSDataDetector`) and lets
   you confirm which kid/school it belongs to before saving.

All three paths produce a common `SchoolEventDTO`, which is upserted into a
SwiftData store shared between the app and the share extension via an App
Group. The main app then syncs everything into a dedicated Calendar-app
calendar per kid ("Emma — School", "Jack — School") using EventKit, so you
see it in whatever calendar app/widget you already use.

## Project layout

```
Shared/                   Compiled into BOTH targets (App Group data model + helpers)
  DTOs/                   Plain Codable types used by the parsers/services
  Persistence/            SwiftData @Model types (local store)
  Services/               EmailParserService (needed by the share extension)
  Utilities/              App Group container access, hashing/HTML-stripping helpers
SchoolSync/               Main app target
  App/                    App entry point + root view
  Services/               ICS fetch/parse, scraping, EventKit sync, sync coordinator
  Utilities/               Date parsing, ICS parsing
  Views/                  SwiftUI screens
SchoolSyncShare/          Share Extension target (receives forwarded/shared emails)
project.yml               XcodeGen project spec (generates the .xcodeproj)
```

## Continuous integration

`.github/workflows/ios-build.yml` builds this on GitHub's hosted macOS
runners on every push — `xcodegen generate` then `xcodebuild build` for a
simulator destination with code signing disabled. It only proves the code
compiles and links; it doesn't sign anything or install on a device, so it
needs no Apple Developer account or secrets. Check the Actions tab for
results after pushing.

## Setup (requires a Mac with Xcode)

This was written in a Linux container with no Xcode/iOS toolchain available,
so none of it has been compiled or run yet. To build it:

1. Install [XcodeGen](https://github.com/yonaskolb/XcodeGen) if you don't have
   it: `brew install xcodegen`
2. From the repo root: `xcodegen generate`
3. Open `SchoolSync.xcodeproj` in Xcode.
4. In both targets' **Signing & Capabilities**, set your Team and change the
   bundle identifiers away from the `com.example.*` placeholders (e.g.
   `com.yourname.schoolsync` and `com.yourname.schoolsync.share`) — Xcode will
   offer to fix the matching App Group identifier, or edit
   `group.com.example.schoolsync` in `project.yml` yourself and re-run
   `xcodegen generate`.
5. Build and run on a device or simulator running iOS 17+ (SwiftData and the
   `EKEventStore.requestFullAccessToEvents` API both require iOS 17).
6. First launch: add each kid, then add each school under that kid, then grant
   Calendar access when prompted, then hit Sync.

## Configuring a school

When you add a school in the app you choose one or more sources:

- **ICS feed URL** — paste the school's calendar feed URL directly.
- **Scrape config** — paste the calendar page URL plus CSS selectors:
  - `eventContainerSelector` — selector matching each event's row/card
  - `titleSelector` (optional, relative to the container)
  - `dateSelector` (optional, relative to the container)
  - `dateAttribute` (optional — if the date lives in an HTML attribute like
    `data-date` rather than the element's text)
  - `locationSelector` (optional)
  - `dateFormat` (optional explicit `DateFormatter` format string; several
    common formats are tried automatically first)

  You'll need to open the school's calendar page, inspect the HTML, and fill
  these in per school — there's no way to do this generically since every
  school site is different.
- **Accept forwarded emails** — toggle this on and the school will appear as
  a destination option in the share-extension confirmation screen.

## Known limitations / next steps

- Scraping selectors are per-school and manual; there's no auto-detection.
- Email parsing is a date-detector heuristic (finds dates in forwarded text
  and uses the email subject as the event title) — good enough to review and
  confirm by hand, not fully automatic.
- `.eml` file attachments shared from Mail are read as raw text in the share
  extension; a proper MIME parser would improve extraction from HTML-heavy
  emails.
- No iCloud/cross-device sync of the SchoolSync database itself (only the
  EventKit calendar it writes to syncs, via your existing iCloud Calendar
  sync).
- No background refresh yet — sync currently runs on demand from Settings.
  Adding a `BGAppRefreshTask` is a natural next step.
- Nothing in this scaffold has been run in Xcode/Simulator — expect to fix
  small build errors on first compile.
