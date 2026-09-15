/**
 * Read-only access for a second parent, a grandparent, a babysitter.
 *
 * See VIEWER_MODE.md for the shape and the reasoning. In short: one phone
 * publishes an encrypted snapshot, other phones read it, and the only thing
 * that travels back is a report saying something looks wrong.
 *
 * Every payload here is opaque. It is encrypted on the phone with a key that
 * moves between devices in a QR code and never touches this Worker, so nothing
 * in this file inspects, parses or logs a payload's contents — and it couldn't
 * if it tried.
 */
import { json } from "./http";
import { randomToken, sha256Hex } from "./auth";

/** Viewer credentials carry a prefix so a token says what it is on sight, and so
 * an owner key doesn't cost a pointless lookup in the viewer table.
 *
 * Not a security boundary, and mutation testing proved it: deleting this check
 * changes no outcome, because the two credential types are hashed into
 * different tables and neither can ever match the other's rows. That structural
 * separation is what does the work. This is a convenience, and calling it
 * anything more would be the kind of comment that makes a later reader trust a
 * line that isn't holding anything up. */
const VIEWER_TOKEN_PREFIX = "vwr_";

/** An invite is scanned in person, but the person doing the scanning may need
 * to install the app first — through TestFlight, on a phone belonging to
 * someone who does not install apps often. An hour is not enough; a day is. */
const INVITE_LIFETIME_MS = 24 * 60 * 60 * 1000;

/** Payload ceiling, comfortably under D1's 2MB per-value limit with room for
 * the rest of the row. A household's whole snapshot — kids, defaults, a year of
 * events and exceptions — is far below this; anything approaching it means
 * something has gone wrong on the phone rather than a family being unusually
 * busy. */
const MAX_PAYLOAD_LENGTH = 1_500_000;

export interface ViewerDevice {
  id: string;
  householdId: string;
}

/**
 * Resolves a viewer device from its bearer token.
 *
 * Returns null for a revoked device, which is what makes revocation immediate
 * rather than "at next login" — there is no session to expire.
 */
export async function authenticateViewer(
  request: Request,
  env: { DB: D1Database }
): Promise<ViewerDevice | null> {
  const header = request.headers.get("authorization") ?? "";
  const match = header.match(/^Bearer\s+(.+)$/i);
  if (!match) return null;

  const token = match[1].trim();
  if (!token.startsWith(VIEWER_TOKEN_PREFIX)) return null;

  const row = await env.DB.prepare(
    `SELECT id, household_id as householdId FROM viewer_devices
     WHERE token_hash = ? AND revoked_at IS NULL`
  )
    .bind(await sha256Hex(token))
    .first<ViewerDevice>();

  if (!row) return null;

  // Recorded so the owner's device list can say "last opened this morning"
  // rather than only "joined in September". A viewer that stopped working is
  // otherwise indistinguishable from one nobody has picked up.
  await env.DB.prepare("UPDATE viewer_devices SET last_seen_at = ? WHERE id = ?")
    .bind(new Date().toISOString(), row.id)
    .run();

  return row;
}

/** Owner creates a single-use invite. The plain code is returned exactly once,
 * to be rendered as a QR; only its hash is stored. */
export async function handleCreateInvite(
  env: { DB: D1Database },
  householdID: string
): Promise<Response> {
  const code = randomToken(16);
  const now = new Date();

  await env.DB.prepare(
    `INSERT INTO viewer_invites (id, household_id, code_hash, created_at, expires_at)
     VALUES (?, ?, ?, ?, ?)`
  )
    .bind(
      crypto.randomUUID(),
      householdID,
      await sha256Hex(code),
      now.toISOString(),
      new Date(now.getTime() + INVITE_LIFETIME_MS).toISOString()
    )
    .run();

  return json({ code, expiresInHours: INVITE_LIFETIME_MS / 3_600_000 });
}

/**
 * A new device exchanges an invite code for its own credential.
 *
 * Unauthenticated by design — the code *is* the credential at this point. It is
 * burned on use, so a QR left on a kitchen table, screenshotted, or forwarded
 * is worthless the moment the intended phone has scanned it.
 */
export async function handleRedeemInvite(
  request: Request,
  env: { DB: D1Database }
): Promise<Response> {
  const body = await request
    .json<{ code?: string; label?: string }>()
    .catch(() => ({}) as { code?: string; label?: string });

  const code = (body.code ?? "").trim();
  if (!code) return json({ error: "missing code" }, 400);

  const invite = await env.DB.prepare(
    `SELECT id, household_id as householdId, expires_at as expiresAt, redeemed_at as redeemedAt
     FROM viewer_invites WHERE code_hash = ?`
  )
    .bind(await sha256Hex(code))
    .first<{ id: string; householdId: string; expiresAt: string; redeemedAt: string | null }>();

  // One message for every failure: unknown, already used, expired. Telling an
  // unknown caller which of those it was would turn this into an oracle for
  // guessing codes.
  const now = new Date();
  if (!invite || invite.redeemedAt || new Date(invite.expiresAt) < now) {
    return json({ error: "invalid or expired code" }, 403);
  }

  const deviceID = crypto.randomUUID();
  const token = `${VIEWER_TOKEN_PREFIX}${randomToken(24)}`;
  const label = (body.label ?? "").trim().slice(0, 60) || null;

  // Burning the invite and creating the device in one batch. Split apart, a
  // failure between them leaves a code that is spent but bought nothing, and
  // the person holding the phone has no way to tell.
  await env.DB.batch([
    env.DB.prepare(
      `INSERT INTO viewer_devices (id, household_id, token_hash, label, created_at)
       VALUES (?, ?, ?, ?, ?)`
    ).bind(deviceID, invite.householdId, await sha256Hex(token), label, now.toISOString()),
    env.DB.prepare(
      "UPDATE viewer_invites SET redeemed_at = ?, redeemed_by_device_id = ? WHERE id = ? AND redeemed_at IS NULL"
    ).bind(now.toISOString(), deviceID, invite.id),
  ]);

  return json({ token });
}

/** The owner's list of joined devices, for showing and revoking. */
export async function handleListViewers(
  env: { DB: D1Database },
  householdID: string
): Promise<Response> {
  const rows = await env.DB.prepare(
    `SELECT id, label, created_at as createdAt, last_seen_at as lastSeenAt
     FROM viewer_devices
     WHERE household_id = ? AND revoked_at IS NULL
     ORDER BY created_at ASC`
  )
    .bind(householdID)
    .all();

  return json({ viewers: rows.results ?? [] });
}

export async function handleRevokeViewer(
  request: Request,
  env: { DB: D1Database },
  householdID: string
): Promise<Response> {
  const body = await request.json<{ id?: string }>().catch(() => ({}) as { id?: string });
  if (!body.id) return json({ error: "missing id" }, 400);

  const result = await env.DB.prepare(
    "UPDATE viewer_devices SET revoked_at = ? WHERE id = ? AND household_id = ? AND revoked_at IS NULL"
  )
    .bind(new Date().toISOString(), body.id, householdID)
    .run();

  return json({ revoked: result.meta.changes === 1 });
}

/** Owner publishes. One snapshot per household, replaced each time. */
export async function handlePublishSnapshot(
  request: Request,
  env: { DB: D1Database },
  householdID: string
): Promise<Response> {
  const body = await request.json<{ payload?: string }>().catch(() => ({}) as { payload?: string });
  const payload = body.payload ?? "";

  if (!payload) return json({ error: "missing payload" }, 400);
  if (payload.length > MAX_PAYLOAD_LENGTH) {
    return json({ error: "payload too large" }, 413);
  }

  const previous = await env.DB.prepare(
    "SELECT version FROM household_snapshots WHERE household_id = ?"
  )
    .bind(householdID)
    .first<{ version: number }>();

  const version = (previous?.version ?? 0) + 1;
  const publishedAt = new Date().toISOString();

  await env.DB.prepare(
    `INSERT INTO household_snapshots (household_id, payload, version, published_at)
     VALUES (?, ?, ?, ?)
     ON CONFLICT(household_id) DO UPDATE SET
       payload = excluded.payload,
       version = excluded.version,
       published_at = excluded.published_at`
  )
    .bind(householdID, payload, version, publishedAt)
    .run();

  return json({ version, publishedAt });
}

/**
 * A viewer (or the owner, checking) fetches the current snapshot.
 *
 * 204 rather than an error when nothing has been published: a viewer that
 * joined before the owner's first sync is in a normal, temporary state, and the
 * app should say "waiting for the first update" rather than show a failure.
 */
export async function handleGetSnapshot(
  env: { DB: D1Database },
  householdID: string
): Promise<Response> {
  const row = await env.DB.prepare(
    `SELECT payload, version, published_at as publishedAt
     FROM household_snapshots WHERE household_id = ?`
  )
    .bind(householdID)
    .first<{ payload: string; version: number; publishedAt: string }>();

  if (!row) return new Response(null, { status: 204 });
  return json(row);
}

/** The one thing a viewer may write. */
export async function handleCreateReport(
  request: Request,
  env: { DB: D1Database },
  viewer: ViewerDevice
): Promise<Response> {
  const body = await request
    .json<{ payload?: string; snapshotVersion?: number }>()
    .catch(() => ({}) as { payload?: string; snapshotVersion?: number });

  const payload = body.payload ?? "";
  if (!payload) return json({ error: "missing payload" }, 400);
  if (payload.length > 20_000) return json({ error: "payload too large" }, 413);

  await env.DB.prepare(
    `INSERT INTO viewer_reports
       (id, household_id, viewer_device_id, payload, snapshot_version, created_at)
     VALUES (?, ?, ?, ?, ?, ?)`
  )
    .bind(
      crypto.randomUUID(),
      viewer.householdId,
      viewer.id,
      payload,
      body.snapshotVersion ?? null,
      new Date().toISOString()
    )
    .run();

  return json({ ok: true });
}

/** Outstanding reports, for the owner. The device label rides along so the app
 * can say who sent it without the owner decrypting anything first. */
export async function handleListReports(
  env: { DB: D1Database },
  householdID: string
): Promise<Response> {
  const rows = await env.DB.prepare(
    `SELECT r.id, r.payload, r.snapshot_version as snapshotVersion,
            r.created_at as createdAt, d.label as viewerLabel
     FROM viewer_reports r
     LEFT JOIN viewer_devices d ON d.id = r.viewer_device_id
     WHERE r.household_id = ? AND r.consumed_at IS NULL
     ORDER BY r.created_at ASC`
  )
    .bind(householdID)
    .all();

  return json({ reports: rows.results ?? [] });
}

export async function handleAckReports(
  request: Request,
  env: { DB: D1Database },
  householdID: string
): Promise<Response> {
  const body = await request.json<{ ids?: string[] }>().catch(() => ({}) as { ids?: string[] });
  const now = new Date().toISOString();

  for (const id of body.ids ?? []) {
    await env.DB.prepare(
      "UPDATE viewer_reports SET consumed_at = ? WHERE id = ? AND household_id = ?"
    )
      .bind(now, id, householdID)
      .run();
  }

  return json({ ok: true });
}
