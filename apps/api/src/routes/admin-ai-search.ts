/**
 * Admin → AI search: the buyer questions, their answers per engine, the
 * diagnosis, and the OWN/CLAIM/EARN/CONTEST source list. Mounted behind the
 * admin role gate in admin.ts. The work itself lives in lib/ai-search/*.
 *
 * No delete routes on purpose: a question is retired with `active: false` so
 * its history stays comparable, and a source is set to `ignore`.
 */

import type { Hono } from "hono";
import { z } from "zod";
import type { Env, Variables } from "../types";
import { parseJsonBody } from "../lib/validate";
import { SOURCE_KINDS, SOURCE_STATUSES } from "../lib/ai-search/analyze";
import { buildOverview, buildQuestionDetail } from "../lib/ai-search/overview";
import { processQueue, startRun } from "../lib/ai-search/runner";
import { generateId } from "../lib/id";

type App = Hono<{ Bindings: Env; Variables: Variables }>;

const nowIso = () => new Date().toISOString();

/** A site path ("/", "/guides/x") — the page meant to answer the question. */
const targetPath = z
  .string()
  .trim()
  .regex(/^\/[A-Za-z0-9._~\-/]*$/, "must be a site path like /guides/…")
  .max(300)
  .nullable();

const QuestionSchema = z.object({
  decision: z.string().trim().min(1).max(120),
  // Perplexity and Claude take at most 500 characters.
  prompt: z.string().trim().min(5).max(500),
  keyword: z.string().trim().min(2).max(200),
  branded: z.boolean().optional(),
  targetPath: targetPath.optional(),
  notes: z.string().max(2000).optional(),
  sort: z.number().int().min(0).max(100_000).optional(),
});

const QuestionPatchSchema = QuestionSchema.partial().extend({ active: z.boolean().optional() });

/** A bare domain ("alternativeto.net") or one page's URL. */
const sourceKey = z
  .string()
  .trim()
  .max(500)
  .refine(
    (s) => /^[a-z0-9-]+(\.[a-z0-9-]+)+$/.test(s) || /^https?:\/\/[^\s]+$/.test(s),
    "must be a lowercase domain or a full URL",
  );

const SourceSchema = z.object({
  key: sourceKey,
  kind: z.enum(SOURCE_KINDS),
  status: z.enum(SOURCE_STATUSES).optional(),
  nextStep: z.string().max(500).optional(),
  url: z.string().trim().url().max(1000).nullable().optional(),
});

export function registerAiSearchAdminRoutes(app: App): void {
  app.get("/admin/ai-search", async (c) => c.json(await buildOverview(c.env)));

  app.get("/admin/ai-search/questions/:id", async (c) => {
    const detail = await buildQuestionDetail(c.env, c.req.param("id"));
    return detail ? c.json(detail) : c.json({ error: "Question not found" }, 404);
  });

  app.post("/admin/ai-search/questions", async (c) => {
    const parsed = await parseJsonBody(c.req, QuestionSchema);
    if (!parsed.ok) return c.json({ error: parsed.error }, 400);
    const q = parsed.data;
    const id = generateId(12);
    const now = nowIso();
    const sort =
      q.sort ??
      ((await c.env.DB.prepare("SELECT COALESCE(MAX(sort), 0) + 10 AS s FROM ai_search_questions").first<{ s: number }>())?.s ?? 0);
    await c.env.DB.prepare(
      `INSERT INTO ai_search_questions (id, decision, prompt, keyword, branded, target_path, active, notes, sort, created_at, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, 1, ?, ?, ?, ?)`,
    ).bind(id, q.decision, q.prompt, q.keyword, q.branded ? 1 : 0, q.targetPath ?? null, q.notes ?? "", sort, now, now).run();
    return c.json({ id }, 201);
  });

  app.patch("/admin/ai-search/questions/:id", async (c) => {
    const parsed = await parseJsonBody(c.req, QuestionPatchSchema);
    if (!parsed.ok) return c.json({ error: parsed.error }, 400);
    const p = parsed.data;
    const sets: string[] = [];
    const vals: unknown[] = [];
    const set = (col: string, v: unknown) => {
      sets.push(`${col} = ?`);
      vals.push(v);
    };
    if (p.decision !== undefined) set("decision", p.decision);
    if (p.prompt !== undefined) set("prompt", p.prompt);
    if (p.keyword !== undefined) set("keyword", p.keyword);
    if (p.branded !== undefined) set("branded", p.branded ? 1 : 0);
    if (p.targetPath !== undefined) set("target_path", p.targetPath);
    if (p.notes !== undefined) set("notes", p.notes);
    if (p.sort !== undefined) set("sort", p.sort);
    if (p.active !== undefined) set("active", p.active ? 1 : 0);
    if (sets.length === 0) return c.json({ error: "Nothing to change" }, 400);
    set("updated_at", nowIso());
    const res = await c.env.DB.prepare(`UPDATE ai_search_questions SET ${sets.join(", ")} WHERE id = ?`)
      .bind(...vals, c.req.param("id"))
      .run();
    if (!res.meta.changes) return c.json({ error: "Question not found" }, 404);
    return c.json({ ok: true });
  });

  /** Start a run now. The first answers come back within the request's
   *  waitUntil; the five-minute cron drains the rest. */
  app.post("/admin/ai-search/runs", async (c) => {
    const started = await startRun(c.env, { kind: "manual", createdBy: c.get("user").uid });
    if (!started.ok) return c.json({ error: started.error, runId: started.runId }, started.status);
    c.executionCtx.waitUntil(
      processQueue(c.env, { budgetMs: 25_000, maxJobs: 12 }).catch((err) => console.error("ai-search kick failed", err)),
    );
    return c.json({ runId: started.runId, jobs: started.jobs }, 202);
  });

  /** Record what we decided to do about a source (upsert by key). */
  app.put("/admin/ai-search/sources", async (c) => {
    const parsed = await parseJsonBody(c.req, SourceSchema);
    if (!parsed.ok) return c.json({ error: parsed.error }, 400);
    const s = parsed.data;
    await c.env.DB.prepare(
      `INSERT INTO ai_search_sources (source_key, kind, status, next_step, url, updated_at, updated_by)
       VALUES (?1, ?2, COALESCE(?3, 'todo'), COALESCE(?4, ''), ?5, ?6, ?7)
       ON CONFLICT (source_key) DO UPDATE SET
         kind = excluded.kind,
         status = COALESCE(?3, ai_search_sources.status),
         next_step = COALESCE(?4, ai_search_sources.next_step),
         url = CASE WHEN ?8 THEN excluded.url ELSE ai_search_sources.url END,
         updated_at = excluded.updated_at,
         updated_by = excluded.updated_by`,
    )
      .bind(s.key, s.kind, s.status ?? null, s.nextStep ?? null, s.url ?? null, nowIso(), c.get("user").uid, s.url !== undefined ? 1 : 0)
      .run();
    return c.json({ ok: true });
  });
}
