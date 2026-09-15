# Viewer mode

One phone publishes. Other phones read.

## Why this shape

A second parent, a grandparent covering for a week, a babysitter — all of them
need the same thing: open the app, see what each kid needs today. None of them
need to add a school, forward an email, or review an extraction.

That asymmetry is the whole design. Read-only removes the expensive half of
syncing: there is no conflict resolution, because nothing ever comes back; no
offline write queue; no per-device acknowledgement race; and nothing to migrate
onto a viewer's phone, because a viewer's phone holds no truth of its own.

The alternative — full two-way sync — is a rewrite of every screen and a
permanent commitment to reconciling edits made in two places at once. This is
two endpoints.

## The pieces

**Owner.** One phone, the one that forwards mail and reviews it. Its local
SwiftData store stays the source of truth exactly as it is today. After each
successful sync it publishes a snapshot.

**Snapshot.** Everything the read-only screens need: kids, per-kid defaults, day
exceptions, and events. Serialized, encrypted on the phone, and PUT to the
backend as one opaque blob. It is *derived* data — a projection of the owner's
store, never the only copy of anything.

**Viewer.** A phone that scanned an invite. It downloads the snapshot,
decrypts it locally, and renders Morning Mode and Calendar. It writes nothing
back except reports.

**Report.** A viewer taps the line that's wrong, picks Wrong / Missing /
Something else, optionally adds a sentence. The report carries which kid, which
day, which field, and which snapshot version it was looking at.

## Encryption

The snapshot and reports are encrypted on-device with a household key. The
backend stores bytes it cannot read.

This costs almost nothing here, and that's worth stating plainly: **the snapshot
is derived data.** If every key were lost tomorrow, nothing is destroyed — the
owner republishes under a new key and viewers re-scan. Losing a key costs a
re-scan, not a calendar. That asymmetry is what makes end-to-end encryption an
easy call in this design and a hard one in most others.

The key travels in the QR code, never through the backend.

Crypto is the single easiest thing to get subtly wrong, so: CryptoKit, one
symmetric key, AES-GCM, no invention.

## Permissions are enforced on the server

The app will hide what a viewer can't do. That is presentation, not permission.

A viewer credential is accepted for exactly two things: fetch the snapshot, post
a report. Every other endpoint refuses it. If the only thing standing between a
viewer and the household's mail queue is which buttons the app draws, that isn't
a rule, it's a suggestion.

## Joining

1. Owner taps *Invite a viewer*. The app asks the backend for a single-use
   invite code and renders a QR containing: backend URL, invite code, household
   key.
2. Viewer installs the app, opens it, taps *Join with a code*, scans.
3. The app redeems the code — single use, so a photographed QR can't be reused —
   and receives its own device token. Each viewer device is separately
   identifiable and separately revocable.
4. The membership lives in the Keychain. Its presence is what puts the app in
   viewer mode. There is no mode picker; a viewer never learns the concept
   exists.

The owner can list joined devices and revoke any of them.

## Staleness is shown, not hidden

A viewer sees a snapshot, not live data. If the owner's phone hasn't opened in
two days, the viewer is reading two-day-old information.

So every viewer screen states when it was last updated, and every report records
which version it was made against. A grandparent acting on stale information is
the one genuinely dangerous failure this design can produce, and the only
defence is to never let the screen look more current than it is.

## Deliberately not in this

- **Viewers cannot edit.** They report; the owner fixes. The moment a viewer can
  write, every conflict problem this design avoids comes straight back.
- **One publisher.** If a second phone ever publishes, two snapshots compete and
  there is no rule for which wins. A second parent is a viewer for now.
- **No push notifications.** Reports appear when the owner next opens the app.
  Real push means APNs certificates and a notification service; worth adding if
  the delay proves to matter, not before.

## The screens

| Screen | Who sees it | What it does |
|---|---|---|
| `WelcomeView` | A blank install only | *Set this up* vs *Join with a code*. Never shown to an install that already has kids, backend credentials or a viewer token. |
| `JoinHouseholdView` | Joining phone | Names the phone, scans the QR (or takes a pasted code), redeems it, and fetches the first snapshot immediately. |
| `ViewersListView` | Owner, under Settings → Sharing | Creates an invite, shows the QR, lists joined phones with last-seen, revokes by swipe. |
| `ViewerSettingsView` | Viewer | Freshness line, *Check for updates*, theme, *Stop following this schedule*. |

Viewer mode is carried down the view tree as `\.isViewer` (see `ViewerMode.swift`)
rather than read from `ViewerSettings` inside each screen — a body that reads a
global keeps whatever it saw first, and six independent checks eventually
disagree with each other.

What that flag turns off: adding a kid from Morning Mode, opening `EditEventView`
from the Calendar, and the swipe-to-delete on an event. All three would let a
viewer make a change that the next snapshot silently reverses, which is worse
than no edit at all because it looks like it worked.

## Two things a viewer does not get

- **Events in the iOS Calendar app.** A viewer's rows live in the app only.
  Writing a household's schedule into a grandparent's own calendar is a bigger
  claim on their phone than following a schedule implies.
- **The school feed URLs.** Stripped when a snapshot is applied. A viewer that
  could fetch a feed itself would immediately drift from the snapshot it exists
  to mirror.

## Leaving

*Stop following this schedule* wipes the local store as well as the credentials.
A phone that has left must not keep showing a family's schedule with no way left
to update or correct it.
