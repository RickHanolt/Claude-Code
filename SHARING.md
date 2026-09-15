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

- **Weather comes from Open-Meteo**, not WeatherKit — no API key, no
  entitlement, no Apple Developer portal step. Free for personal use; if this
  ever became a real product that licence is the first thing to re-read.
- **Morning Mode splits evenly for two kids and scrolls past that.** Untested
  with three.
- **`BlockWord` shrinks to fit but has no floor.** A very long name would render
  unreadably small rather than truncating or wrapping.
- **Errors surface as raw `localizedDescription`.** Fine for a developer, poor
  for anyone else — "The data couldn't be read because it isn't in the correct
  format" meant nothing until it was diagnosed.
- **Attachments are dropped by rule, not by capability.** HEIC is the common
  one — a photo taken on a phone can't be read by the API and can't be
  transcoded in a Worker, so it's refused with an explanation. Someone else
  will hit this on their first forward. A real fix converts on the way in,
  which needs an image service rather than a rule.
- **The debug fetch endpoint should go.** It's admin-gated and host-allowlisted,
  but it's a URL-fetching endpoint that exists only so a parser could be written
  against a real response. Delete it once MealViewer is settled.

---

## If you open this up — what the first version actually looks like

The list above says what's wrong. This says what you'd do about it, in order,
and — more usefully — what you'd deliberately not do.

The goal being sketched here is narrow: **a friend sets this up alone, for their
own kids, without you on the phone.** That is a much smaller project than
selling anything, and it's the one that would tell you whether the larger
question is worth asking.

### 1. Self-serve provisioning — the hard stop for everyone

Covered above as a blocker; this is the shape of the fix. A "create household"
call that mints the household, its key and its ingest address in one step, and a
screen that shows the address with a copy button. The household table already
exists, so the endpoint is small.

The real cost isn't the code. It's that from that day you are running an account
system: recovery when someone reinstalls, deletion when someone leaves, and
support when something goes wrong on a phone you cannot reach. That is the first
genuine commitment on this list, and it doesn't get smaller later.

### 2. The Gmail filter — where people will actually drop off

Even handed an address, a friend has to build a forwarding rule in Gmail, and
Gmail requires verifying the destination before it will forward anything. That's
several screens deep in settings and it is not something code can do for them.

The fix is an unglamorous illustrated walkthrough in the app, plus a "nothing has
arrived yet" state that distinguishes *you haven't finished setup* from *no mail
has come in*. Expect this step, not the interesting one below, to be where most
people give up.

### 3. School calendar discovery — the rabbit hole, and probably skippable

Nobody knows where their school's ICS feed lives. This project is its own proof:
a news RSS URL was entered as the calendar feed and the app showed nothing at
all for weeks without ever saying so.

The automated version — take the school's website, look for calendar feeds,
recognise the handful of platforms most school sites run on, verify the result
actually parses as a calendar with school-year-shaped events — is a genuinely
interesting problem and could consume a month.

**Skip it in the first version.** The email path is the universal one: every
school emails parents, and not every school has a findable feed. The ICS feed
here supplies the semester grid, but the things that actually change a morning —
picture day, early dismissal, no lunch service — all arrived by email. Make the
email path self-serve, leave "paste a feed URL" as an optional extra, and most
of the value is covered for a fraction of the work.

### 4. A "does this look right?" screen

After setup, show the next thirty days and ask them to confirm it before they
start relying on it. Small, and it's the difference between having installed an
app and believing it.

### What you owe the people testing it

The moment a friend's household exists, another family's children — names,
schools, and which days they're off — are in the same D1 database as yours, and
`forwarded_emails` stores message bodies in plaintext. For friends who know you
that is probably fine. It should still be a thing you told them rather than a
thing they would be surprised to learn.

The honest minimum before the first outside household:

- **A delete-my-household endpoint** that actually removes the rows. An hour of
  work, and the thing you cannot credibly promise without it.
- **A sentence about what's stored and where**, given to them directly. Not a
  privacy policy — just the truth, once, in plain words.
- **Sender allowlisting** (see above), because an ingest address in someone
  else's hands is an address that can be given out, guessed at, or subscribed to
  a newsletter, and every message costs a model call.

### What this is not

None of the above makes this a product. It makes it testable by people who are
not you, which is the only way to find out what's actually missing. The
questions that decide whether it could ever be a business — whether the unit is
a household or a school, who pays for extraction, and what it means to hold a
database of where other people's children are on any given day — are not
answered by any of this work, and are best asked after a handful of real
families have used it for a term.
