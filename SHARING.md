# What has to change before anyone else can use this

SchoolSync currently works for exactly one family, and a fair amount of that is
load-bearing rather than incidental. This is the list of things that are fine
while it's yours and become problems the moment a second household exists.

Kept as a running list rather than reconstructed later, because most of these
are only obvious while the decision that caused them is fresh — and because
"we'll notice at the time" is how a one-family app quietly becomes a rewrite.

Nothing here blocks your own use. Ordered roughly by how painful it is to fix
late.

---

## Blocking — someone else literally cannot use it

**Onboarding is a markdown file and a curl command.**
`INGEST_BACKEND.md` walks through registering a domain, creating a D1 database,
minting an API token, setting four GitHub secrets, and provisioning a household
with an admin token. That's a working setup process for someone who runs the
backend. It is not something you can hand a friend. A shared version needs
self-serve signup in the app: create household, get an ingest address, store the
key — with no dashboard and no terminal.

**One Anthropic key pays for everyone.**
Extraction bills to whoever owns `ANTHROPIC_API_KEY`. At one household that's a
few dollars a month. At twenty it's someone's actual bill, with no per-household
accounting, no cap, and no way to tell whose forwarded PDF cost $2. Needs at
minimum a per-household usage counter and a ceiling; realistically, a decision
about who pays.

**The admin token provisions unlimited households.**
`/v1/households` is protected by a single shared secret. Anyone holding it can
create households indefinitely — and it's synced from a GitHub secret to the
Worker on every deploy, so its blast radius is the whole backend. Fine as a
private setup tool; not an endpoint that should exist once other people's data
is in the same database.

**Kid and school setup assumes you already know the answers.**
Adding a school means knowing its ICS feed URL or writing a scrape config. You
had those; a friend won't. Needs either a school directory or a much more
forgiving "paste a link and we'll work it out" flow.

---

## Serious — works, but wrong for other people

**Timezone defaults to America/Chicago.**
Per household in the schema, so the hard part is done, but nothing exposes it:
provisioning doesn't ask and there's no UI to change it. A family in Denver gets
every stated time shifted an hour with nothing on screen explaining why. Given
this exact bug already shipped once as a five-hour offset, it deserves an
explicit setup step rather than a default nobody sees.

**Sender filtering doesn't exist.**
Anything sent to a household's ingest address is stored and extracted. Right now
that's controlled by which Gmail filters you set up. Shared, it's an address
anyone can guess the shape of, that spends money per message. Needs an allowlist
of sending addresses per household.

**Attachment size and count are capped per attachment, not per household.**
Nothing stops a single household forwarding a hundred PDFs an hour. Every one is
stored and extracted. Needs rate limiting before the address is out of your
control.

**MealViewer school and grade band are hardcoded to Teddy's.**
The parser is general; the configuration isn't. Belongs on `SchoolRecord`
alongside the ICS feed — a menu source and a grade band per school.

**Grade band matching is string-based on district-typed names.**
"K-8 GNG Breakfast" versus "K-8 Express Lunch" shows districts don't follow a
template. Matching "K-8" and "breakfast" works for CPS; another district may
publish "Elementary AM Meal" and quietly match nothing. Should degrade to the
kid's default (it does) but also tell someone it found no block, which it
currently doesn't.

---

## Structural — invisible until it isn't

**The whole household shares one calendar review queue.**
`/v1/pending` returns everything for a household with no notion of who is
looking. Two parents on two phones both see the same pending emails and can both
save them, producing duplicate local events with no shared "already handled"
state. Fine for one phone.

**Duplicate suppression is per-household and per-instant.**
Two families forwarding the same district newsletter are correctly independent.
But two *parents* in one household forwarding it are also independent, and the
content hash only catches it if the bytes match after header stripping. Related
to the point above: there's no per-user identity anywhere in the system.

**The app's local store is the source of truth for kids and defaults.**
Kid identity deliberately never reaches the backend, which is good for privacy
and means the backend can't attribute anything by itself. The cost is that a
household with two phones has two independent sets of kids, defaults and
exceptions, with no sync. A second parent installing the app starts from empty.
This is the biggest structural assumption in the project and the most expensive
to revisit.

**No migration story for the local store.**
SwiftData models have been changed repeatedly by adding defaulted properties,
which is fine. A rename or a type change would need a real migration plan, and
there isn't one. Worth having before other people's data is in there.

---

## Polish — noticeable but not dangerous

- **Weather is stubbed.** Needs the WeatherKit capability in the Apple Developer
  portal and Apple's attribution in the UI.
- **Morning Mode splits evenly for two kids and scrolls past that.** Untested
  with three.
- **`BlockWord` shrinks to fit but has no floor.** A very long name would render
  unreadably small rather than truncating or wrapping.
- **Errors surface as raw `localizedDescription`.** Fine for a developer, poor
  for anyone else — "The data couldn't be read because it isn't in the correct
  format" meant nothing until it was diagnosed.
- **No way to see extraction failures in the app.** `extraction_error` is
  recorded on the row but only visible via a SQL console.
- **The debug fetch endpoint should go.** It's admin-gated and host-allowlisted,
  but it's a URL-fetching endpoint that exists only so a parser could be written
  against a real response. Delete it once MealViewer is settled.
