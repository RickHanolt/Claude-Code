/**
 * Exercises the viewer endpoints against a real SQLite database.
 *
 * These handlers decide who can read a household's data, so a typecheck is not
 * evidence. Every migration is applied to an in-memory database and the
 * handlers run against it unmodified, through a shim thin enough that what's
 * under test is the actual code rather than a paraphrase of it.
 *
 * The properties that matter most and are least visible by reading:
 * an invite works once, a revoked device stops immediately, and a viewer
 * credential is not a household credential.
 */
import { DatabaseSync } from "node:sqlite";
import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { sha256Hex, randomToken } from "../src/auth";
import {
  authenticateViewer,
  handleCreateInvite,
  handleCreateReport,
  handleGetSnapshot,
  handleListReports,
  handleListViewers,
  handlePublishSnapshot,
  handleRedeemInvite,
  handleRevokeViewer,
} from "../src/viewers";

let failures = 0;

function check(name: string, actual: unknown, expected: unknown) {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    console.error(`  FAIL ${name}: got ${JSON.stringify(actual)}, expected ${JSON.stringify(expected)}`);
    failures += 1;
  }
}

/** The smallest surface of D1 these handlers actually use. */
function makeDB(db: DatabaseSync) {
  const prepare = (sql: string) => {
    let args: unknown[] = [];
    const self = {
      bind(...values: unknown[]) {
        args = values.map((v) => (v === undefined ? null : v));
        return self;
      },
      first<T>(): T | null {
        return (db.prepare(sql).get(...(args as never[])) as T) ?? null;
      },
      all<T>(): { results: T[] } {
        return { results: db.prepare(sql).all(...(args as never[])) as T[] };
      },
      run() {
        const info = db.prepare(sql).run(...(args as never[]));
        return { meta: { changes: Number(info.changes) } };
      },
    };
    return self;
  };

  return {
    prepare,
    async batch(statements: ReturnType<typeof prepare>[]) {
      for (const statement of statements) statement.run();
    },
  } as unknown as D1Database;
}

function post(body: unknown, token?: string): Request {
  return new Request("https://example.test/", {
    method: "POST",
    body: JSON.stringify(body),
    headers: token ? { authorization: `Bearer ${token}` } : {},
  });
}

const sqlite = new DatabaseSync(":memory:");
for (const file of readdirSync("migrations").sort()) {
  sqlite.exec(readFileSync(join("migrations", file), "utf8"));
}

const DB = makeDB(sqlite);
const env = { DB };

const householdID = crypto.randomUUID();
const householdKey = randomToken(24);
sqlite
  .prepare("INSERT INTO households (id, name, ingest_slug, api_key_hash, created_at) VALUES (?, ?, ?, ?, ?)")
  .run(householdID, "Test", "test-abc", await sha256Hex(householdKey), new Date().toISOString());

// --- invites ---------------------------------------------------------------

const invite = await (await handleCreateInvite(env, householdID)).json<{ code: string }>();
check("an invite returns a code", typeof invite.code, "string");

const redeemed = await handleRedeemInvite(post({ code: invite.code, label: "Mum's iPhone" }), env);
const { token } = await redeemed.json<{ token: string }>();
check("redeeming returns a viewer token", token.startsWith("vwr_"), true);

// The property a photographed QR depends on.
const second = await handleRedeemInvite(post({ code: invite.code }), env);
check("an invite cannot be redeemed twice", second.status, 403);

check("an unknown code is refused", (await handleRedeemInvite(post({ code: "nope" }), env)).status, 403);

const expired = crypto.randomUUID();
const past = new Date(Date.now() - 1000).toISOString();
sqlite
  .prepare("INSERT INTO viewer_invites (id, household_id, code_hash, created_at, expires_at) VALUES (?, ?, ?, ?, ?)")
  .run(expired, householdID, await sha256Hex("expired-code"), past, past);
check("an expired invite is refused", (await handleRedeemInvite(post({ code: "expired-code" }), env)).status, 403);

// --- who a credential is ---------------------------------------------------

const viewer = await authenticateViewer(post({}, token), env);
check("a viewer token resolves to its household", viewer?.householdId, householdID);

// The structural half of the permission boundary: a viewer credential is not a
// household credential, so every owner-only endpoint refuses it without needing
// a check of its own.
const asHousehold = sqlite
  .prepare("SELECT id FROM households WHERE api_key_hash = ?")
  .get(await sha256Hex(token));
check("a viewer token is not a household key", asHousehold, undefined);

// And the reverse, or an owner key would quietly grant viewer access too.
check("a household key is not a viewer token", await authenticateViewer(post({}, householdKey), env), null);

check("no credential resolves to nobody", await authenticateViewer(post({}), env), null);

// Deliberately untested: the VIEWER_TOKEN_PREFIX check in authenticateViewer.
// Mutation testing showed removing it changes no outcome — an owner key hashed
// against viewer_devices finds nothing either way. It's a convenience, not a
// boundary, and a test asserting otherwise would be theatre.

// --- snapshots -------------------------------------------------------------

check("no snapshot yet is 204, not an error", (await handleGetSnapshot(env, householdID)).status, 204);

const first = await (await handlePublishSnapshot(post({ payload: "ciphertext-one" }), env, householdID)).json<{ version: number }>();
check("the first publish is version 1", first.version, 1);

const again = await (await handlePublishSnapshot(post({ payload: "ciphertext-two" }), env, householdID)).json<{ version: number }>();
check("publishing again increments the version", again.version, 2);

const current = await (await handleGetSnapshot(env, householdID)).json<{ payload: string; version: number }>();
check("the latest payload is served", current.payload, "ciphertext-two");
check("only one snapshot is kept", Number(sqlite.prepare("SELECT COUNT(*) AS n FROM household_snapshots").get()!.n), 1);

check(
  "an oversized payload is refused",
  (await handlePublishSnapshot(post({ payload: "x".repeat(1_600_000) }), env, householdID)).status,
  413
);
check("an empty payload is refused", (await handlePublishSnapshot(post({}), env, householdID)).status, 400);

// --- reports ---------------------------------------------------------------

await handleCreateReport(post({ payload: "encrypted-report", snapshotVersion: 2 }), env, viewer!);
const reports = await (await handleListReports(env, householdID)).json<{
  reports: { payload: string; snapshotVersion: number; viewerLabel: string }[];
}>();
check("the report reaches the owner", reports.reports[0].payload, "encrypted-report");
// Without this a report is unmoored: "the lunch is wrong" gives no way to tell
// whether its author was looking at current data.
check("the report names the version it was made against", reports.reports[0].snapshotVersion, 2);
check("the report says which device sent it", reports.reports[0].viewerLabel, "Mum's iPhone");

// --- revocation ------------------------------------------------------------

const listed = await (await handleListViewers(env, householdID)).json<{ viewers: { id: string }[] }>();
check("the joined device is listed", listed.viewers.length, 1);

await handleRevokeViewer(post({ id: listed.viewers[0].id }), env, householdID);
// Immediate, not at next launch — there is no session to outlive.
check("a revoked device stops authenticating", await authenticateViewer(post({}, token), env), null);
check("a revoked device leaves the list", (await (await handleListViewers(env, householdID)).json<{ viewers: unknown[] }>()).viewers.length, 0);

if (failures > 0) {
  console.error(`${failures} viewer failure(s).`);
  process.exit(1);
}
console.log("Viewers: all cases OK.");
