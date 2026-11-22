/**
 * Runs: ask every active question of every configured engine, then let the
 * cron drain the answers.
 *
 * Starting a run inserts one 'pending' ai_search_results row per question ×
 * engine × sample and checks the target pages. The rows ARE the queue:
 * processQueue claims them one at a time with an atomic UPDATE … RETURNING,
 * so the five-minute cron, a manual "Run now" and an overlapping invocation
 * never answer the same row twice. A live DataForSEO call can take two
 * minutes, so a run spans several invocations by design.
 */

import type { Env } from "../../types";
import { generateId } from "../id";
import { judgeAnswer, domainOf, type EngineId } from "./analyze";
import { ENGINES, RetryLater, askEngine, engineConfigured, engineInfo } from "./engines";
import { checkPages } from "./page-check";

const DAY_MS = 86_400_000;
/** A 'running' row older than this was orphaned by a dead invocation. */
const STALE_MS = 10 * 60_000;
const MAX_ATTEMPTS = 3;
const MAX_ANSWER_CHARS = 8_000;
const MAX_SOURCES = 20;
/** Google's AI Overview references are stored after the organic results, from this position. */
export const OVERVIEW_POSITION_BASE = 100;

const nowIso = () => new Date().toISOString();

export function configuredEngines(env: Env) {
  return ENGINES.filter((e) => engineConfigured(env, e));
}

/** Days between scheduled runs; 0 turns the schedule off. */
export function scheduleDays(env: Env): number {
  const n = Number(env.AI_SEARCH_SCHEDULE_DAYS ?? "7");
  return Number.isFinite(n) && n >= 0 ? n : 7;
}

export type StartResult =
  | { ok: true; runId: string; jobs: number }
  | { ok: false; status: 400 | 409; error: string; runId?: string };

export async function startRun(
  env: Env,
  opts: { kind: "schedule" | "manual"; createdBy: string | null },
): Promise<StartResult> {
  const running = await env.DB.prepare("SELECT id FROM ai_search_runs WHERE status = 'running' LIMIT 1").first<{ id: string }>();
  if (running) return { ok: false, status: 409, error: "A run is already in progress", runId: running.id };

  const engines = configuredEngines(env);
  if (engines.length === 0) {
    return { ok: false, status: 400, error: "No engine is configured: set GEMINI_API_KEY or the DataForSEO login" };
  }
  const { results: questions } = await env.DB.prepare(
    "SELECT id, prompt, keyword, target_path FROM ai_search_questions WHERE active = 1 ORDER BY sort, id",
  ).all<{ id: string; prompt: string; keyword: string; target_path: string | null }>();
  if (!questions?.length) return { ok: false, status: 400, error: "No active questions" };

  const runId = generateId(16);
  const now = nowIso();
  const stmts: D1PreparedStatement[] = [
    env.DB.prepare(
      "INSERT INTO ai_search_runs (id, kind, engines, status, created_at, created_by) VALUES (?, ?, ?, 'running', ?, ?)",
    ).bind(runId, opts.kind, JSON.stringify(engines.map((e) => e.id)), now, opts.createdBy),
  ];
  for (const q of questions) {
    for (const e of engines) {
      for (let s = 0; s < e.samples; s++) {
        stmts.push(
          env.DB.prepare(
            `INSERT INTO ai_search_results (id, run_id, question_id, engine, sample, prompt, status)
             VALUES (?, ?, ?, ?, ?, ?, 'pending')`,
          ).bind(generateId(16), runId, q.id, e.id, s, e.kind === "search" ? q.keyword : q.prompt),
        );
      }
    }
  }
  await env.DB.batch(stmts);

  // The crawl check rides along: a failure here never blocks the run.
  try {
    const paths = [...new Set(questions.map((q) => q.target_path).filter((p): p is string => !!p))];
    const checks = await checkPages(paths);
    if (checks.length) {
      await env.DB.batch(
        checks.map((c) =>
          env.DB.prepare(
            "INSERT OR REPLACE INTO ai_search_page_checks (run_id, path, checked_at, http_status, problems, words) VALUES (?, ?, ?, ?, ?, ?)",
          ).bind(runId, c.path, nowIso(), c.httpStatus, JSON.stringify(c.problems), c.words),
        ),
      );
    }
  } catch (err) {
    console.error("ai-search page checks failed", err);
  }

  return { ok: true, runId, jobs: stmts.length - 1 };
}

/** Hourly: start a run when the last one is older than the schedule. */
export async function maybeStartScheduledRun(env: Env, now = Date.now()): Promise<string | null> {
  const days = scheduleDays(env);
  if (days === 0 || configuredEngines(env).length === 0) return null;
  const last = await env.DB.prepare("SELECT created_at FROM ai_search_runs ORDER BY created_at DESC LIMIT 1").first<{ created_at: string }>();
  if (last && now - Date.parse(last.created_at) < days * DAY_MS) return null;
  const started = await startRun(env, { kind: "schedule", createdBy: null });
  return started.ok ? started.runId : null;
}

interface Job {
  id: string;
  run_id: string;
  question_id: string;
  engine: EngineId;
  prompt: string;
  attempts: number;
}

async function claim(env: Env, engine: EngineId): Promise<Job | null> {
  return env.DB.prepare(
    `UPDATE ai_search_results SET status = 'running', started_at = ?1, attempts = attempts + 1
      WHERE id = (SELECT id FROM ai_search_results WHERE status = 'pending' AND engine = ?2
                   ORDER BY run_id, question_id, sample LIMIT 1)
        AND status = 'pending'
     RETURNING id, run_id, question_id, engine, prompt, attempts`,
  )
    .bind(nowIso(), engine)
    .first<Job>();
}

async function answer(env: Env, job: Job): Promise<"ok" | "error" | "retry"> {
  try {
    const a = await askEngine(env, job.engine, job.prompt);
    const v = judgeAnswer(job.engine, a);
    const organic = a.sources.slice(0, MAX_SOURCES);
    const overview = (a.overviewSources ?? []).slice(0, MAX_SOURCES);
    const rows = [
      ...organic.map((s, i) => ({ ...s, position: i + 1 })),
      ...overview.map((s, i) => ({ ...s, position: OVERVIEW_POSITION_BASE + i + 1 })),
    ];
    await env.DB.batch([
      env.DB.prepare(
        `UPDATE ai_search_results
            SET status = 'ok', finished_at = ?, model = ?, mentioned = ?, cited = ?, rank = ?, own_url = ?,
                brands = ?, queries = ?, answer = ?, cost_usd = ?, error = NULL
          WHERE id = ?`,
      ).bind(
        nowIso(), a.model, v.mentioned ? 1 : 0, v.cited ? 1 : 0, v.rank, v.ownUrl,
        JSON.stringify(v.brands.slice(0, 30)), JSON.stringify(a.queries.slice(0, 20)),
        a.text.slice(0, MAX_ANSWER_CHARS), a.costUsd, job.id,
      ),
      ...rows.map((s) =>
        env.DB.prepare(
          "INSERT OR REPLACE INTO ai_search_result_sources (result_id, position, domain, url, title) VALUES (?, ?, ?, ?, ?)",
        ).bind(job.id, s.position, domainOf(s.url) ?? "", s.url.slice(0, 2000), s.title.slice(0, 300)),
      ),
    ]);
    return "ok";
  } catch (err) {
    // Busy, not this question's fault: back in the queue. A rate limit refunds
    // the attempt; an overloaded upstream spends it, so one that stays down
    // ends in an error below instead of looping run after run.
    if (err instanceof RetryLater && (err.refund || job.attempts < MAX_ATTEMPTS)) {
      await env.DB.prepare(
        `UPDATE ai_search_results SET status = 'pending', started_at = NULL, attempts = attempts - ${err.refund ? 1 : 0} WHERE id = ?`,
      ).bind(job.id).run();
      return "retry";
    }
    const message = err instanceof Error ? err.message : String(err);
    await env.DB.prepare(
      "UPDATE ai_search_results SET status = 'error', finished_at = ?, error = ? WHERE id = ?",
    ).bind(nowIso(), message.slice(0, 500), job.id).run();
    return "error";
  }
}

export interface QueueReport {
  answered: number;
  failed: number;
  finishedRuns: number;
}

/**
 * Drain pending answers until `budgetMs` has passed (calls already in flight
 * finish). Each engine is its own lane with its own concurrency, so a slow
 * engine never holds up a fast one, and a rate-limited one stops alone.
 */
export async function processQueue(env: Env, opts: { budgetMs: number; maxJobs?: number }): Promise<QueueReport> {
  const started = Date.now();
  // Each answer is ~25 D1 statements and up to ~11 subrequests; the cap keeps
  // one invocation well inside the Workers per-invocation limits.
  let claimsLeft = opts.maxJobs ?? 30;
  const now = nowIso();
  const staleBefore = new Date(Date.now() - STALE_MS).toISOString();
  await env.DB.batch([
    env.DB.prepare(
      "UPDATE ai_search_results SET status = 'pending', started_at = NULL WHERE status = 'running' AND started_at < ? AND attempts < ?",
    ).bind(staleBefore, MAX_ATTEMPTS),
    env.DB.prepare(
      `UPDATE ai_search_results SET status = 'error', finished_at = ?, error = 'Gave up after ${MAX_ATTEMPTS} attempts'
        WHERE status = 'running' AND started_at < ? AND attempts >= ?`,
    ).bind(now, staleBefore, MAX_ATTEMPTS),
  ]);

  const { results: pendingEngines } = await env.DB.prepare(
    "SELECT DISTINCT engine FROM ai_search_results WHERE status = 'pending'",
  ).all<{ engine: EngineId }>();

  const report: QueueReport = { answered: 0, failed: 0, finishedRuns: 0 };
  const lanes: Promise<void>[] = [];
  for (const { engine } of pendingEngines ?? []) {
    const info = ENGINES.find((e) => e.id === engine);
    if (!info || !engineConfigured(env, info)) {
      // The secret went away mid-run: close these out instead of waiting forever.
      await env.DB.prepare(
        "UPDATE ai_search_results SET status = 'error', finished_at = ?, error = 'Engine not configured' WHERE status = 'pending' AND engine = ?",
      ).bind(now, engine).run();
      continue;
    }
    let busy = false;
    const worker = async () => {
      while (!busy && claimsLeft > 0 && Date.now() - started < opts.budgetMs) {
        claimsLeft--;
        const job = await claim(env, engine);
        if (!job) return;
        const outcome = await answer(env, job);
        if (outcome === "ok") report.answered++;
        else if (outcome === "error") report.failed++;
        else busy = true;
      }
    };
    for (let i = 0; i < engineInfo(engine).concurrency; i++) lanes.push(worker());
  }
  await Promise.all(lanes);

  const done = await env.DB.prepare(
    `UPDATE ai_search_runs SET status = 'done', finished_at = ?
      WHERE status = 'running'
        AND NOT EXISTS (SELECT 1 FROM ai_search_results r
                         WHERE r.run_id = ai_search_runs.id AND r.status IN ('pending', 'running'))`,
  ).bind(nowIso()).run();
  report.finishedRuns = done.meta.changes ?? 0;
  return report;
}

/** Cheap check for the five-minute cron: is there anything to do? */
export async function hasPendingAnswers(env: Env): Promise<boolean> {
  const row = await env.DB.prepare(
    "SELECT 1 AS x FROM ai_search_results WHERE status IN ('pending', 'running') LIMIT 1",
  ).first<{ x: number }>();
  return !!row;
}
