# Auto-forward backend (Ingest/)

Optional add-on: instead of manually sharing each school email into
SchoolSync, set up a mail rule that auto-forwards matching senders to a
dedicated address, and the app picks the results up automatically. This is
a genuine architecture change from the rest of the app — everywhere else is
on-device only; this path means your kids' school emails transit a
Cloudflare Worker and small database you run. Skip this file entirely if
you'd rather keep sharing emails by hand.

Everything below happens on [dash.cloudflare.com](https://dash.cloudflare.com)
(free account) plus GitHub's web UI — no Mac, no terminal required. Where a
step needs a value pasted into this repo (a database ID, a domain name),
tell it to me and I'll edit the file and push, same as we did for bundle
IDs and signing config earlier.

## 1. Cloudflare account

Sign up at [dash.cloudflare.com/sign-up](https://dash.cloudflare.com/sign-up)
if you don't already have one. Free plan covers everything here.

## 2. Register a domain

**Websites** in the left sidebar → **Register Domain** → pick something
cheap (a `.com`/`.net`/whatever, doesn't matter which — it's never shown to
anyone, just used as the receiving address). Registering directly through
Cloudflare means DNS is already pointed correctly, no separate delegation
step. Cost is usually $10–15/year, charged by Cloudflare.

## 3. Turn on Email Routing

Once the domain shows as **Active**: open it → **Email Routing** in the
left sidebar → **Enable Email Routing**. Cloudflare adds the necessary MX
records automatically since it also runs your DNS. Leave the routing rules
alone for now — we'll point them at the Worker in step 8, after it exists.

## 4. Create the D1 database

**Workers & Pages** → **D1 SQL Database** → **Create database** → name it
`schoolsync_ingest` → Create. On the database's page, copy the **Database
ID** (a UUID) and send it to me — I'll paste it into `Ingest/wrangler.toml`
in place of `REPLACE_WITH_D1_DATABASE_ID` and push.

## 5. Create an API token for GitHub Actions

**My Profile** (account icon, top right) → **API Tokens** → **Create
Token** → **Custom token**. Give it:

- **Permissions:** Account → Workers Scripts → Edit, and Account → D1 →
  Edit
- **Account Resources:** Include → your account

Create it, copy the token (shown once).

Also grab your **Account ID** — visible in the right sidebar of almost any
page in the dashboard, or under **Workers & Pages** → Overview.

## 6. Add GitHub repository secrets

In this repo: **Settings → Secrets and variables → Actions → New repository
secret**, add three:

| Name | Value |
|---|---|
| `CLOUDFLARE_API_TOKEN` | the token from step 5 |
| `CLOUDFLARE_ACCOUNT_ID` | the account ID from step 5 |
| `INGEST_ADMIN_TOKEN` | any long random string you make up — this becomes the password that protects the "create a household" endpoint. A password generator's output is fine; save it somewhere, you'll need it again in step 9. |

## 7. Point the worker at your domain

Tell me the domain you registered in step 2. I'll set `INGEST_DOMAIN` in
`Ingest/wrangler.toml` to it and push — that push triggers
`.github/workflows/ingest-deploy.yml`, which applies the D1 migrations and
deploys the Worker for the first time. Check the **Actions** tab; once
green, the Worker exists at `schoolsync-ingest.<your-subdomain>.workers.dev`.

## 8. Route incoming mail to the worker

Back in **Email Routing → Routing rules**: under **Catch-all address**, set
the action to **Send to a Worker** and pick `schoolsync-ingest`. This
routes *any* address at your domain to the Worker — the Worker itself
looks up which household owns the address and silently rejects anything
that doesn't match, so you don't need a separate routing rule per kid or
per school.

## 9. Provision your household

This creates the actual receiving address + the API key the iOS app will
use to poll for new emails. From any machine with a browser, open
[reqbin.com](https://reqbin.com) (or any HTTP request tool) and send:

- **Method:** POST
- **URL:** `https://schoolsync-ingest.<your-subdomain>.workers.dev/v1/households`
- **Header:** `Authorization: Bearer <your INGEST_ADMIN_TOKEN from step 6>`
- **Body (JSON):** `{"name": "Hanolt"}`

The response is `{"ingestAddress": "...", "apiKey": "..."}` — **copy both,
the API key is shown exactly once and can't be recovered** (you'd have to
provision a new household if you lose it). These two values go into the
app's Settings once that screen exists (tracked separately — the iOS side
of this isn't built yet).

## 10. Set up the actual forwarding

In Gmail/Outlook/iCloud Mail: create a filter/rule per school — "from
contains `@theirschool.org`" → **forward to** the `ingestAddress` from step
9. Now those emails land in the Worker without you touching Mail at all.

## How it works once it's live

1. School email arrives at `<slug>@yourdomain.com`.
2. Cloudflare Email Routing hands it to the Worker's `email()` handler
   (`Ingest/src/index.ts`), which parses it, looks up the household by
   address slug, runs the same date-detection heuristic as the on-device
   share extension (`Ingest/src/dateParser.ts`, a TypeScript port of
   `Shared/Services/EmailParserService.swift`), and stores the full email
   plus any candidate dates in D1.
3. The app polls `GET /v1/pending` with its API key, shows the same kind
   of confirmation screen the share extension uses today, and calls
   `POST /v1/ack` once it's pulled items into its local store.

## Known limitations

- Same-day filtering in `dateParser.ts` compares calendar days in UTC
  (no timezone info is known server-side), which can occasionally miss or
  over-suppress a match right around midnight in your local timezone —
  the on-device version doesn't have this issue since it uses the
  device's own calendar/timezone.
- No self-serve signup UI for `/v1/households` — it's a single
  admin-token-protected endpoint, provisioned by hand once. Fine for a
  household or two, not meant to scale beyond that.
- `postal-mime` parses the raw MIME message; heavily HTML-formatted school
  newsletters may extract with more noise than plain-text emails, same
  caveat as the `.eml` handling in the share extension.
