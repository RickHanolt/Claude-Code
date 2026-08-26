# Building SchoolSync without a Mac

This is the checklist for getting SchoolSync onto your iPhone via TestFlight
using only cloud services — Codemagic builds and signs it, Apple's App Store
Connect API key is what lets it do that automatically, and TestFlight is how
the signed build reaches your phone. `codemagic.yaml` in the repo root
defines the actual build steps; this document is everything *around* that
file that only you can do, because it requires your own Apple ID, payment,
and account authorizations that I have no access to.

Total cost: **$99/year** (Apple Developer Program). Codemagic's free tier
(500 build minutes/month) should easily cover occasional builds of an app
this size.

## 1. Enroll in the Apple Developer Program

<https://developer.apple.com/programs/enroll> — sign in with your Apple ID,
pay the $99/year fee. This can take anywhere from a few minutes to a day or
two if Apple needs to verify your identity. Nothing else below works until
this is approved.

## 2. Register identifiers in the Apple Developer portal

At <https://developer.apple.com/account/resources/identifiers/list>, all
from a browser, no Mac needed:

1. **App Group** — go to the "App Groups" tab, click **+**, enter
   `group.com.rickhanolt.schoolsync` as the identifier, any description.
2. **App ID for the app** — "App IDs" tab, click **+**, choose *App*,
   explicit Bundle ID `com.rickhanolt.schoolsync`, and under Capabilities
   check **App Groups**, then associate it with the group you just created.
3. **App ID for the share extension** — same process, Bundle ID
   `com.rickhanolt.schoolsync.share`, also with the App Groups capability
   associated to the same group.

Registering these two App IDs yourself first (rather than letting
Codemagic's `--create` flag improvise) is what guarantees the App Groups
capability is actually attached — that capability is what lets the app and
the share extension read/write the same local data.

If you ever want to use a different bundle ID prefix than
`com.rickhanolt.schoolsync`, change it in `project.yml`, `codemagic.yaml`,
and `Shared/Utilities/AppGroup.swift` together, and register the matching
identifiers here instead.

## 3. Create the app record in App Store Connect

At <https://appstoreconnect.apple.com> → Apps → **+** → New App:

- Platform: iOS
- Name: "SchoolSync" (or anything else if that's taken — display name only,
  doesn't need to match the bundle ID)
- Bundle ID: select `com.rickhanolt.schoolsync` from the dropdown (it should
  appear here once step 2 is done)
- SKU: any unique string, e.g. `schoolsync001`

The share extension doesn't get its own App Store Connect app record — it's
just embedded in and signed alongside the main app.

## 4. Create an App Store Connect API key

App Store Connect → **Users and Access** → **Integrations** tab → **App
Store Connect API** → **Team Keys** → **Generate API Key**.

- Name it anything (e.g. "Codemagic CI")
- Access role: **Admin** — this needs to cover both Certificates/Identifiers/
  Profiles management (for creating the signing certificate) and TestFlight
  uploads, and Admin is the simplest role that's guaranteed to cover both
  without guessing at Apple's exact permission matrix.
- Download the `.p8` private key file **immediately** — Apple only lets you
  download it once, ever. Note the **Key ID** and **Issuer ID** shown on the
  same page.

**Never commit this `.p8` file to the repo.** It's a real credential — it
only goes into Codemagic's own encrypted integration storage (next step).

## 5. Connect Codemagic

1. Sign up at <https://codemagic.io>, easiest via "Continue with GitHub" —
   this is also how you grant it access to this repository.
2. **Team settings → Integrations → Apple Developer Portal** → add a new
   integration → paste the Issuer ID, Key ID, and upload the `.p8` file from
   step 4. **Name the integration exactly `schoolsync_asc`** — that's the
   name `codemagic.yaml` references. (If you name it something else, update
   `integrations.app_store_connect` in `codemagic.yaml` to match, and push
   that change.)
3. **Applications → Add application** → select this GitHub repo. Codemagic
   should detect `codemagic.yaml` automatically and offer the
   `ios-testflight` workflow.

## 6. Generate a certificate private key and add it to Codemagic

`codemagic.yaml`'s signing steps use `app-store-connect fetch-signing-files
--create` to have Apple issue a new "Apple Distribution" certificate. That
command needs a private key to build the certificate request from — it does
**not** generate one itself, which is what caused the
`Cannot save Signing Certificates without certificate private key` error if
you hit it on an earlier attempt.

1. Generate an RSA private key (PEM, starts with
   `-----BEGIN RSA PRIVATE KEY-----`). On macOS/Linux, or Git Bash on
   Windows:
   ```
   openssl genrsa -traditional -out key.pem 2048
   ```
   (`-traditional` matters — without it, modern OpenSSL defaults to PKCS#8
   output, `-----BEGIN PRIVATE KEY-----` with no "RSA", which Apple's
   tooling doesn't expect.) On Windows without Git Bash:
   `ssh-keygen -t rsa -b 2048 -m PEM -f key -q -N ""` works with the
   built-in OpenSSH client instead.
2. Base64-encode it onto a single line — don't paste the raw multi-line PEM
   into Codemagic's variable field directly; a multi-line secret is an easy
   way for a web form to silently mangle it (this is exactly what caused an
   `argument --certificate-key: Not a valid certificate private key` error
   during setup). On macOS/Linux: `base64 -i key.pem | tr -d '\n'` (macOS)
   or `base64 -w0 key.pem` (Linux) prints one continuous line — copy that.
3. In Codemagic, go to your app → **Settings** → **Environment variables**
   (the *app-level* page — the older global/team-level "codemagic.yaml
   settings" page is being phased out for personal accounts and won't work).
4. Add a new variable:
   - Name: `CERTIFICATE_PRIVATE_KEY_B64`
   - Value: the single-line base64 text from step 2
   - Mark it **Secret** so it's encrypted and hidden from build logs
   - Group: create/select a group named exactly **`ios_signing`** — that's
     what `codemagic.yaml` references under `environment.groups`
5. Save. `codemagic.yaml`'s "Decode certificate private key" step turns this
   back into a real PEM file at build time and verifies it with
   `openssl rsa -check` before any signing step touches it. Delete your
   local copy of `key.pem` once the variable is saved — you don't need to
   keep it, and it's a real credential like the `.p8` file.

## 7. Run the first build

From the Codemagic dashboard: **Start new build** → branch
`claude/getting-started-coding-bcrw93` → workflow `ios-testflight`. Watch the
log.

This first run is genuinely untested by me — I don't have a Codemagic
account to try it against, so treat the first attempt as a debugging pass.
If a step fails, the error message will usually say exactly what's
missing (a capability not attached, a wrong integration name, etc.) — send
me the log and I'll fix `codemagic.yaml` or the project config.

## 8. Install it on your iPhone

Once the build succeeds, `codemagic.yaml` uploads it to TestFlight
automatically. In App Store Connect → your app → **TestFlight** tab, add
yourself as an internal tester if you're not already listed as one (internal
testers are just the team members on your Apple Developer account, so this
is usually automatic).

On your iPhone: install the free **TestFlight** app from the App Store,
accept the invite (email or a link from App Store Connect), then install
SchoolSync from there. Every future successful Codemagic build updates it
the same way — no manual reinstall needed.
