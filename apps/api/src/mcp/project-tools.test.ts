/**
 * The cloud-project editing tools end to end, through the REAL Worker
 * entrypoint (src/index.ts), the real migrations (node:sqlite), the session
 * routes that create the fixtures (stage → upload → finalize → save), and
 * the same save/restore code the editor uses.
 *
 * Mocked: the Better Auth session store (fake-session: bearer = uid), the S3
 * presigner, R2 (in memory, ranged reads included) and `fetch` (unused).
 */

import { beforeEach, describe, expect, it, vi } from "vitest";
import type { Env } from "../types";
import { createTestD1, type TestD1 } from "../test-support/d1-sqlite.js";
import { MemoryBucket, gunzipText } from "../test-support/memory-bucket";
import { mp4File } from "../test-support/mp4-boxes";
import { AGENT_SCOPES, createAgentToken, type AgentScope } from "../lib/agent-tokens";
import { objectKey, sha256Hex } from "../lib/cloud-projects";
import { EDITING_PLAYBOOK, ops, newUUID } from "../lib/editor-core";
import { newProject, serializeProjectText, parseProjectText } from "../../../web/src/editor/core/model";
import { findTool } from "./tools";
import type { CallToolResult } from "./server";

vi.mock("cloudflare:workers", () => ({ DurableObject: class {} }));
vi.mock("../lib/auth", () => import("../test-support/fake-session"));
vi.mock("../lib/presign", async (importOriginal) => ({
  ...(await importOriginal<typeof import("../lib/presign")>()),
  createPresignedDownloadUrl: vi.fn(async ({ key }: { key: string }) => `https://r2.test/signed/${key}`),
  createPresignedUploadUrl: vi.fn(async ({ key }: { key: string }) => `https://r2.test/${key}?put`),
}));
vi.stubGlobal("caches", { default: { match: async () => undefined, put: async () => undefined, delete: async () => true } });
vi.stubGlobal(
  "fetch",
  vi.fn(async () => {
    throw new Error("offline test: unexpected fetch");
  }),
);

const { default: worker } = await import("../index");

const OWNER = "owner"; // tester → Pro
const OTHER = "other"; // tester → Pro, a different account
const API = "http://localhost:8787";
const PID = "3F2504E0-4F89-11D3-9A0C-0305E82C3301";
const OTHER_PID = "9C1D5E2A-0B7F-4A61-8D3E-2F6A7B8C9D01";
/** Background work (webhook emits) the Worker hands to waitUntil — awaited by tests that check it. */
const pending: Promise<unknown>[] = [];
const ctx = { waitUntil(p: Promise<unknown>) { pending.push(p); }, passThroughOnException() {} } as unknown as ExecutionContext;
const macDir = (id: string) => `file:///Users/test/Library/Application%20Support/CaptureCat/Projects/${id}`;

let db: TestD1;
let env: Env;
let bucket: MemoryBucket;
let seq = 0;

beforeEach(() => {
  seq = 0;
  db = createTestD1();
  bucket = new MemoryBucket();
  env = {
    DB: db,
    R2: bucket,
    BETTER_AUTH_URL: API,
    BETTER_AUTH_SECRET: "test-secret-test-secret-test-secret-00",
    R2_ENDPOINT: "https://account.r2.test",
    R2_ACCESS_KEY_ID: "k",
    R2_SECRET_ACCESS_KEY: "s",
  } as unknown as Env;
  const now = new Date().toISOString();
  for (const [id, name] of [
    [OWNER, "Olive Owner"],
    [OTHER, "Otto Other"],
  ]) {
    db.query(
      `INSERT INTO "user" (id, name, email, emailVerified, createdAt, updatedAt, tester, blocked) VALUES (?, ?, ?, 1, ?, ?, 1, 0)`,
      id, name, `${id}@test.local`, now, now,
    );
  }
});

// ---------------------------------------------------------------------------
// Session-side fixtures (the editor's own routes)
// ---------------------------------------------------------------------------

function session(uid: string, method: string, path: string, body?: string | object, headers: Record<string, string> = {}) {
  const h: Record<string, string> = { Authorization: `Bearer ${uid}`, ...headers };
  let payload: string | undefined;
  if (typeof body === "string") payload = body;
  else if (body !== undefined) {
    payload = JSON.stringify(body);
    h["Content-Type"] = "application/json";
  }
  return worker.fetch(new Request(`${API}/api${path}`, { method, headers: h, body: payload }), env, ctx);
}

interface FixtureFile {
  path: string;
  contentType: string;
  bytes: Uint8Array;
}
const text = (s: string) => new TextEncoder().encode(s);

const cursorRecording = {
  version: 1,
  coordinateWidth: 1470,
  coordinateHeight: 956,
  events: Array.from({ length: 20 * 30 + 1 }, (_, i) => {
    const t = i / 30;
    const presses = [[2, 2.06], [2.7, 2.76], [9, 9.06], [9.8, 9.86]];
    return { timestamp: t, x: t < 6 ? 300 : 1100, y: t < 6 ? 250 : 700, isClick: presses.some(([a, b]) => t >= a && t < b) };
  }),
};

function projectDocument(id: string, name: string): string {
  return serializeProjectText(
    newProject({
      id,
      name,
      duration: 20,
      createdAt: 780000000.5,
      videoURL: `${macDir(id)}/recording.mov`,
      cursorDataURL: `${macDir(id)}/cursor.json`,
    }),
  );
}

/** Stage → upload → finalize → first save, as `uid`; returns the document. */
async function createProject(uid: string, id: string, name: string): Promise<string> {
  const files: FixtureFile[] = [
    { path: "recording.mov", contentType: "video/quicktime", bytes: mp4File({ tracks: [{ kind: "video", width: 2940, height: 1912 }], mdatBytes: 2048 }) },
    { path: "cursor.json", contentType: "application/json", bytes: text(JSON.stringify(cursorRecording)) },
    { path: "thumbnail.jpg", contentType: "image/jpeg", bytes: text(`thumb-${id}`) },
  ];
  const manifest = {
    name,
    files: await Promise.all(files.map(async (f) => ({ path: f.path, sha256: await sha256Hex(f.bytes), bytes: f.bytes.byteLength, contentType: f.contentType }))),
  };
  const stage = await session(uid, "PUT", `/cloud-projects/${id}`, manifest);
  expect(stage.status, await stage.clone().text()).toBe(200);
  for (const f of files) await bucket.put(objectKey(uid, id, await sha256Hex(f.bytes)), f.bytes);
  const fin = await session(uid, "POST", `/cloud-projects/${id}/finalize`);
  expect(fin.status, await fin.clone().text()).toBe(200);
  const doc = projectDocument(id, name);
  const saved = await session(uid, "PUT", `/cloud-projects/${id}/project`, doc, { "If-Match": '"0"', "X-CC-Client": "mac" });
  expect(saved.status, await saved.clone().text()).toBe(200);
  return doc;
}

async function currentDocument(id: string, uid = OWNER): Promise<{ revision: number; document: string }> {
  const res = await session(uid, "GET", `/cloud-projects/${id}`);
  expect(res.status).toBe(200);
  return (await res.json()) as { revision: number; document: string };
}

/** A person saving in the editor: rename the project on top of the current revision. */
async function humanRename(name: string) {
  const { revision, document } = await currentDocument(PID);
  const doc = JSON.parse(document) as Record<string, unknown>;
  doc.name = name;
  const res = await session(OWNER, "PUT", `/cloud-projects/${PID}/project`, JSON.stringify(doc, null, 2), {
    "If-Match": `"${revision}"`,
    "X-CC-Client": "web",
    "X-CC-Source": "human",
  });
  expect(res.status, await res.clone().text()).toBe(200);
}

// ---------------------------------------------------------------------------
// MCP side
// ---------------------------------------------------------------------------

async function token(scopes: readonly AgentScope[] = AGENT_SCOPES, uid = OWNER) {
  const created = await createAgentToken(db, { uid, name: "Claude", scopes: [...scopes], expiresInDays: null });
  return { token: created.token, id: created.summary.id };
}

async function call(tok: string, name: string, args: Record<string, unknown> = {}): Promise<CallToolResult> {
  const res = await worker.fetch(
    new Request(`${API}/mcp`, {
      method: "POST",
      headers: { "Content-Type": "application/json", Accept: "application/json, text/event-stream", Authorization: `Bearer ${tok}` },
      body: JSON.stringify({ jsonrpc: "2.0", id: ++seq, method: "tools/call", params: { name, arguments: args } }),
    }),
    env,
    ctx,
  );
  const body = (await res.json()) as { result: CallToolResult; error?: unknown };
  expect(res.status, JSON.stringify(body)).toBe(200);
  expect(body.error).toBeUndefined();
  return body.result;
}

/** A successful result whose structuredContent parses as the outputSchema (and loses nothing). */
// eslint-disable-next-line @typescript-eslint/no-explicit-any -- asserted field by field
function structured(name: string, result: CallToolResult): any {
  expect(result.isError, result.content.map((c) => ("text" in c ? c.text : c.type)).join("\n")).toBeFalsy();
  const sc = result.structuredContent!;
  expect(findTool(name)!.output.parse(sc)).toEqual(sc);
  return sc;
}

function errorText(result: CallToolResult): string {
  expect(result.isError).toBe(true);
  return (result.content[0] as { text: string }).text;
}

interface VersionRow {
  id: string;
  seq: number;
  kind: string;
  revision: number;
  actor_uid: string;
  client_kind: string;
  client_id: string | null;
  source: string;
  change_json: string | null;
  restored_from: string | null;
}
const versions = (id = PID) => db.query<VersionRow>(`SELECT * FROM cloud_project_versions WHERE project_id = ? ORDER BY seq`, id);
const revisionOf = (id = PID) => db.query<{ revision: number }>(`SELECT revision FROM cloud_projects WHERE id = ?`, id)[0].revision;

const ZOOM_BATCH = {
  ops: [
    { op: "add_effect", args: { type: "zoom", start: 2, end: 5, zoomLevel: 1.8, focalX: 0.3, focalY: 0.35 } },
    { op: "add_annotation", args: { type: "text", start: 2.5, end: 4.5, x: 0.5, y: 0.15, text: "Choose a plan" } },
    { op: "set_style", args: { patch: { backgroundPadding: 72 } } },
  ],
};

// ---------------------------------------------------------------------------

describe("list_projects / describe_project", () => {
  it("lists the account's own projects with durations, thumbnail and editor URL — never another account's", async () => {
    await createProject(OWNER, PID, "Checkout demo");
    await createProject(OTHER, OTHER_PID, "Someone else's");
    const { token: t } = await token();
    const sc = structured("list_projects", await call(t, "list_projects"));
    expect(sc.total).toBe(1);
    expect(sc.projects).toEqual([
      expect.objectContaining({
        id: PID,
        name: "Checkout demo",
        revision: 1,
        durationSeconds: 20,
        outputDurationSeconds: 20,
        thumbnailUrl: expect.stringContaining(`https://r2.test/signed/cloud-projects/${OWNER}/${PID}/objects/`),
        editorUrl: `http://localhost:3200/app/editor/${PID}`,
      }),
    ]);
    expect(sc.untrusted).toBe(true);
    // The other account sees only its own.
    const { token: o } = await token(AGENT_SCOPES, OTHER);
    expect(structured("list_projects", await call(o, "list_projects")).projects.map((p: { id: string }) => p.id)).toEqual([OTHER_PID]);
  });

  it("describes the project in the Mac/WebMCP shape, with the cursor digest read from R2", async () => {
    const doc = await createProject(OWNER, PID, "Checkout demo");
    const { token: t } = await token();
    const sc = structured("describe_project", await call(t, "describe_project", { project_id: PID.toLowerCase() }));
    // Exactly the shared op's payload, plus the remote keys.
    const { revision, editorUrl, untrusted, ...payload } = sc;
    expect([revision, editorUrl, untrusted]).toEqual([1, `http://localhost:3200/app/editor/${PID}`, true]);
    const expected = ops.jsonSafe(
      ops.describeProject(parseProjectText(doc), {
        cursor: cursorRecording.events,
        screenSize: { width: 1470, height: 956 },
        keystrokes: [],
        silence: null,
      }),
    );
    expect(payload).toEqual(expected);
    expect(payload.interactionDigest).toBeDefined();
    expect(payload.audio).toBeUndefined();
  });
});

describe("apply_edits", () => {
  it("fires the owner's project.saved webhook, marked as an agent save", async () => {
    await createProject(OWNER, PID, "Checkout demo");
    const hook = await session(OWNER, "POST", "/webhooks", { url: "https://hooks.example.com/cc", events: ["project.saved"] });
    expect(hook.status, await hook.clone().text()).toBe(201);
    const { token: t } = await token();
    pending.length = 0;
    const sc = structured("apply_edits", await call(t, "apply_edits", { project_id: PID, ...ZOOM_BATCH }));
    await Promise.allSettled(pending);
    const rows = db.query<{ event: string; payload: string }>(`SELECT event, payload FROM webhook_deliveries`);
    expect(rows.map((r) => r.event)).toEqual(["project.saved"]);
    expect(JSON.parse(rows[0].payload).data).toMatchObject({ projectId: PID, revision: sc.revision, savedBy: "agent" });
  });

  it("saves a new revision with agent provenance, and the change round-trips through describe_project", async () => {
    const doc = await createProject(OWNER, PID, "Checkout demo");
    const { token: t, id: tokenId } = await token();
    const sc = structured("apply_edits", await call(t, "apply_edits", { project_id: PID, ...ZOOM_BATCH }));
    expect(sc).toMatchObject({ projectId: PID, revision: 2, applied: 3, retriedAfterConflict: false });
    const zoomId = sc.results[0].result.created[0].id as string;
    const annotationId = sc.results[1].result.created as string;

    // History: a new version made by an agent (no client app), with the change-set.
    const vs = versions();
    expect(vs.map((v) => [v.seq, v.kind, v.source, v.client_kind])).toEqual([
      [1, "upload", "human", "mac"],
      [2, "edit", "agent", "unknown"],
    ]);
    expect(vs[1]).toMatchObject({ id: sc.versionId, actor_uid: OWNER, client_id: `mcp-${tokenId}`, revision: 2 });
    const change = JSON.parse(vs[1].change_json!);
    expect(change.items.zoomRegions.added).toEqual([zoomId]);
    expect(change.items.annotations.added).toEqual([annotationId]);

    // The stored document is what the web editor would have saved.
    const expected = (() => {
      const p = parseProjectText(doc);
      // Replay with the ids the server generated, in creation order.
      const created = [zoomId, annotationId];
      let n = 0;
      ops.applyEditsBatch(p, ZOOM_BATCH.ops, { newId: () => created[n++] ?? newUUID(), autoZoom: () => 0, stillMotion: () => 0 });
      return serializeProjectText(p);
    })();
    const stored = await currentDocument(PID);
    expect(stored.revision).toBe(2);
    expect(stored.document).toBe(expected);

    // Round trip: describe_project reads the edit back.
    const described = structured("describe_project", await call(t, "describe_project", { project_id: PID }));
    expect(described.revision).toBe(2);
    expect(described.effects.zoomRegions).toEqual([
      { id: zoomId, start: 2, end: 5, zoomLevel: 1.8, focalPoint: { x: 0.3, y: 0.35 } },
    ]);
    expect(described.annotations).toEqual([expect.objectContaining({ type: "text", text: "Choose a plan", start: 2.5, end: 4.5 })]);
    expect(described.settings.backgroundPadding).toBe(72);

    // A second edit by the same agent moments later joins the same version.
    const again = structured("apply_edits", await call(t, "apply_edits", { project_id: PID, ops: [{ op: "set_trim", args: { start: 1 } }] }));
    expect(again.revision).toBe(3);
    expect(again.versionId).toBe(sc.versionId);

    // Audited with the project id.
    const audit = db.query<{ tool: string; video_id: string; ok: number }>(`SELECT tool, video_id, ok FROM agent_audit_log ORDER BY rowid`);
    expect(audit.filter((a) => a.tool === "apply_edits")).toEqual([
      { tool: "apply_edits", video_id: PID, ok: 1 },
      { tool: "apply_edits", video_id: PID, ok: 1 },
    ]);
  });

  it("is all-or-nothing: a failing op saves nothing and returns the editor's error text", async () => {
    await createProject(OWNER, PID, "Checkout demo");
    const { token: t } = await token();
    const res = await call(t, "apply_edits", {
      project_id: PID,
      ops: [
        { op: "add_effect", args: { type: "zoom", start: 2, end: 5 } },
        { op: "add_effect", args: { type: "zoom", start: 4, end: 6 } }, // overlaps on the one EFFECTS lane
      ],
    });
    expect(errorText(res)).toMatch(/^apply_edits: ops\[1\] \(add_effect\) failed — .*Nothing was written/);
    expect(revisionOf()).toBe(1);
    // Unknown ops are refused by the schema before anything runs.
    expect(errorText(await call(t, "apply_edits", { project_id: PID, ops: [{ op: "delete_project" }] }))).toContain("Invalid arguments");
    expect(revisionOf()).toBe(1);
  });

  it("auto_zoom reads cursor.json and the recording's size from R2", async () => {
    await createProject(OWNER, PID, "Checkout demo");
    const { token: t } = await token();
    const sc = structured("apply_edits", await call(t, "apply_edits", { project_id: PID, ops: [{ op: "auto_zoom" }] }));
    expect(sc.results[0].result.created).toBeGreaterThan(0);
    const described = structured("describe_project", await call(t, "describe_project", { project_id: PID }));
    expect(described.effects.zoomRegions.every((z: { auto?: boolean }) => z.auto === true)).toBe(true);
  });
});

describe("If-Match conflicts", () => {
  /** Run `fn` once when the agent writes its document snapshot, `times` times. */
  function concurrentSaveOnAgentWrite(times: number) {
    const put = bucket.put.bind(bucket);
    let busy = false;
    let left = times;
    bucket.put = (async (key: string, value: Uint8Array, opts?: Parameters<MemoryBucket["put"]>[2]) => {
      if (left > 0 && !busy && key.includes("/doc/")) {
        left--;
        busy = true;
        try {
          await humanRename(`Renamed ${times - left}`);
        } finally {
          busy = false;
        }
      }
      return put(key, value, opts);
    }) as MemoryBucket["put"];
  }

  it("a save that lands mid-edit is re-read and the batch re-applied once on top of it", async () => {
    await createProject(OWNER, PID, "Checkout demo");
    const { token: t } = await token();
    concurrentSaveOnAgentWrite(1);
    const sc = structured("apply_edits", await call(t, "apply_edits", { project_id: PID, ...ZOOM_BATCH }));
    expect(sc).toMatchObject({ revision: 3, retriedAfterConflict: true });
    // Both changes survive: the person's rename and the agent's zoom.
    const doc = JSON.parse((await currentDocument(PID)).document);
    expect(doc.name).toBe("Renamed 1");
    expect(doc.zoomRegions).toHaveLength(1);
    expect(versions().map((v) => v.source)).toEqual(["human", "human", "agent"]);
    // The losing attempt's snapshot was cleaned up.
    expect(bucket.docKeys().filter((k) => k.includes("/doc/2-"))).toHaveLength(1);
  });

  it("a second clash is a clear conflict error and the agent's edit is not saved", async () => {
    await createProject(OWNER, PID, "Checkout demo");
    const { token: t } = await token();
    concurrentSaveOnAgentWrite(2);
    const res = await call(t, "apply_edits", { project_id: PID, ...ZOOM_BATCH });
    expect(errorText(res)).toMatch(/^Edit conflict on .*Nothing was written/);
    const doc = JSON.parse((await currentDocument(PID)).document);
    expect(doc.name).toBe("Renamed 2");
    expect(doc.zoomRegions).toHaveLength(0);
    expect(versions().every((v) => v.source === "human")).toBe(true);
  });
});

describe("access, scopes and plan gate", () => {
  it("another account's project is invisible to every tool", async () => {
    await createProject(OTHER, OTHER_PID, "Private");
    const { token: t } = await token();
    for (const [name, args] of [
      ["describe_project", { project_id: OTHER_PID }],
      ["style_options", { project_id: OTHER_PID }],
      ["apply_edits", { project_id: OTHER_PID, ...ZOOM_BATCH }],
      ["set_style", { project_id: OTHER_PID, patch: { backgroundPadding: 10 } }],
      ["list_versions", { project_id: OTHER_PID }],
      ["restore_version", { project_id: OTHER_PID, version_id: versions(OTHER_PID)[0].id }],
      ["open_in_editor", { project_id: OTHER_PID }],
    ] as const) {
      expect(errorText(await call(t, name, args)), name).toBe(
        `No cloud project "${OTHER_PID}" in this account. Use list_projects to find project ids.`,
      );
    }
    // Same answer as a project that does not exist at all.
    expect(errorText(await call(t, "describe_project", { project_id: newUUID() }))).toMatch(/^No cloud project/);
    expect(revisionOf(OTHER_PID)).toBe(1);
  });

  it("needs projects:read to look and projects:write to edit", async () => {
    await createProject(OWNER, PID, "Checkout demo");
    const { token: none } = await token(["videos:read"]);
    expect(errorText(await call(none, "list_projects"))).toContain('lacks the "projects:read" scope');
    const { token: reader } = await token(["projects:read"]);
    structured("describe_project", await call(reader, "describe_project", { project_id: PID }));
    structured("list_versions", await call(reader, "list_versions", { project_id: PID }));
    for (const [name, args] of [
      ["apply_edits", { project_id: PID, ...ZOOM_BATCH }],
      ["set_style", { project_id: PID, patch: { backgroundPadding: 10 } }],
      ["restore_version", { project_id: PID, version_id: versions()[0].id }],
    ] as const) {
      expect(errorText(await call(reader, name, args)), name).toContain('lacks the "projects:write" scope');
    }
    expect(revisionOf()).toBe(1);
  });

  it("every project tool is gated on the plan's agentEditing feature", async () => {
    await createProject(OWNER, PID, "Checkout demo");
    const { token: t } = await token();
    db.query(`UPDATE plan SET features = json_set(features, '$.agentEditing', json('false')) WHERE name = 'pro'`);
    for (const tool of ["list_projects", "describe_project", "style_options", "get_editing_playbook", "apply_edits", "set_style", "list_versions", "restore_version", "open_in_editor"]) {
      const args: Record<string, unknown> = { project_id: PID };
      if (tool === "apply_edits") Object.assign(args, ZOOM_BATCH);
      if (tool === "set_style") args.patch = { backgroundPadding: 10 };
      if (tool === "restore_version") args.version_id = versions()[0].id;
      expect(errorText(await call(t, tool, args)), tool).toContain("isn't included in the account's");
    }
    expect(revisionOf()).toBe(1);
    // The video tools are untouched by the flag.
    expect((await call(t, "list_videos")).isError).toBeFalsy();
  });
});

describe("set_style, style_options, playbook, editor URL", () => {
  it("set_style validates through the shared ops and saves", async () => {
    await createProject(OWNER, PID, "Checkout demo");
    const { token: t } = await token();
    const sc = structured("set_style", await call(t, "set_style", { project_id: PID, patch: { aspectRatio: "9:16", backgroundPadding: 40 } }));
    expect(sc).toMatchObject({ revision: 2, applied: { aspectRatio: "9:16", backgroundPadding: 40 } });
    expect(errorText(await call(t, "set_style", { project_id: PID, patch: { backgroundPading: 3 } }))).toContain(
      "key not whitelisted: backgroundPading — did you mean 'backgroundPadding'",
    );
    const options = structured("style_options", await call(t, "style_options", { project_id: PID, group: "canvas" }));
    expect(Object.keys(options.groups)).toEqual(["canvas"]);
    expect(options.groups.canvas.aspectRatio.current).toBe("9:16");
    expect(revisionOf()).toBe(2);
  });

  it("get_editing_playbook is the desktop playbook plus every op's arguments", async () => {
    const { token: t } = await token(["projects:read"]);
    const res = await call(t, "get_editing_playbook");
    const sc = structured("get_editing_playbook", res);
    expect(sc.playbook).toBe(EDITING_PLAYBOOK);
    expect(Object.keys(sc.ops)).toEqual([...ops.EDIT_OP_NAMES]);
    expect(sc.ops.add_effect.args.properties.id).toBeUndefined();
    expect(sc.ops.add_effect.args.properties.zoomLevel).toBeDefined();
    expect((res.content[0] as { text: string }).text).toContain(EDITING_PLAYBOOK);
  });

  it("open_in_editor returns the web editor URL", async () => {
    await createProject(OWNER, PID, "Checkout demo");
    const { token: t } = await token(["projects:read"]);
    expect(structured("open_in_editor", await call(t, "open_in_editor", { project_id: PID }))).toEqual({
      projectId: PID,
      url: `http://localhost:3200/app/editor/${PID}`,
      revision: 1,
    });
  });
});

describe("list_versions / restore_version", () => {
  it("restores an earlier version as a NEW agent revision; nothing is deleted", async () => {
    const original = await createProject(OWNER, PID, "Checkout demo");
    const { token: t } = await token();
    structured("apply_edits", await call(t, "apply_edits", { project_id: PID, ...ZOOM_BATCH }));

    const listed = structured("list_versions", await call(t, "list_versions", { project_id: PID }));
    expect(listed.versions.map((v: { kind: string; source: string; isHead: boolean }) => [v.kind, v.source, v.isHead])).toEqual([
      ["edit", "agent", true],
      ["upload", "human", false],
    ]);
    expect(listed.versions[0].change.items.zoomRegions.added).toHaveLength(1);
    const upload = listed.versions[1];

    const sc = structured("restore_version", await call(t, "restore_version", { project_id: PID, version_id: upload.id }));
    expect(sc).toMatchObject({ projectId: PID, revision: 3, restoredFrom: upload.id, retriedAfterConflict: false });

    // The document is the upload's again, byte for byte.
    expect((await currentDocument(PID)).document).toBe(original);
    const vs = versions();
    expect(vs.map((v) => [v.seq, v.kind, v.source])).toEqual([
      [1, "upload", "human"],
      [2, "edit", "agent"],
      [3, "restore", "agent"],
    ]);
    expect(vs[2]).toMatchObject({ id: sc.versionId, restored_from: upload.id, actor_uid: OWNER });
    // The agent's edit is still in history and its snapshot still stored.
    const editKey = db.query<{ doc_r2_key: string }>(`SELECT doc_r2_key FROM cloud_project_versions WHERE seq = 2`)[0].doc_r2_key;
    expect(JSON.parse(await gunzipText(bucket.objects.get(editKey)!.bytes)).zoomRegions).toHaveLength(1);
    const described = structured("describe_project", await call(t, "describe_project", { project_id: PID }));
    expect(described.effects.zoomRegions).toEqual([]);

    // Restoring the current version is refused (nothing to do); bad ids are clear.
    expect(errorText(await call(t, "restore_version", { project_id: PID, version_id: sc.versionId }))).toMatch(/already the current version/);
    expect(errorText(await call(t, "restore_version", { project_id: PID, version_id: "zzzzzzzz00000000" }))).toMatch(/^No version/);
  });
});
