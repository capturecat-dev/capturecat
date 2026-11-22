/**
 * Everything the admin "AI search" page shows, assembled from the tables in
 * one pass: the questions with their latest answer per engine and their
 * diagnosis, the run history with its rates, the OWN/CLAIM/EARN/CONTEST
 * source list, the crawl checks, and AI-search vs Google traffic (step 8 of
 * the loop: the two are measured separately, and against real visits).
 */

import type { Env } from "../../types";
import { classifySource as classifyTraffic } from "../traffic-source";
import { utmSourceOf } from "../signup-attribution";
import {
  diagnose,
  runMetrics,
  snapshot,
  classifySource,
  isOwnUrl,
  KIND_ACTIONS,
  ENGINE_IDS,
  type Diagnosis,
  type EngineId,
  type EngineSnapshot,
  type ResultLite,
  type RunMetrics,
  type SourceDecision,
  type SourceKind,
  type SourceStatus,
} from "./analyze";
import { ENGINES, engineRoute } from "./engines";
import { OVERVIEW_POSITION_BASE, scheduleDays } from "./runner";

const RUN_HISTORY = 12;
const TRAFFIC_WEEKS = 8;

export interface QuestionRow {
  id: string;
  decision: string;
  prompt: string;
  keyword: string;
  branded: boolean;
  targetPath: string | null;
  active: boolean;
  notes: string;
  sort: number;
  latest: Partial<Record<EngineId, EngineSnapshot>>;
  diagnosis: Diagnosis;
  /** Per run, oldest first: mean AI mention rate for this question. */
  history: Array<{ runId: string; createdAt: string; mentionRate: number | null }>;
}

export interface RunRow {
  id: string;
  kind: string;
  status: string;
  createdAt: string;
  finishedAt: string | null;
  engines: EngineId[];
  jobs: { total: number; done: number; failed: number };
  costUsd: number;
  metrics: RunMetrics;
}

export interface SourceRow {
  key: string;
  domain: string;
  kind: SourceKind;
  /** No decision recorded yet: `kind` is the suggestion. */
  suggested: boolean;
  status: SourceStatus | null;
  nextStep: string;
  url: string | null;
  /** In the latest answers: times an AI engine (or Google's AI Overview) cited it. */
  aiCitations: number;
  /** In the latest answers: keywords where it holds a Google top-10 result. */
  googleTop10: number;
  questions: string[];
  engines: EngineId[];
  topUrls: string[];
}

export interface PageCheckRow {
  path: string;
  checkedAt: string;
  httpStatus: number | null;
  problems: string[];
  words: number | null;
}

export interface TrafficWeek {
  /** Monday, YYYY-MM-DD (UTC). */
  week: string;
  aiVisits: number;
  googleVisits: number;
  aiDownloads: number;
  googleDownloads: number;
  aiSignups: number;
  googleSignups: number;
}

export interface AiSearchOverview {
  /** `via`/`route`: how this Worker asks the engine now; null = off. */
  engines: Array<{ id: EngineId; label: string; kind: "ai" | "search"; via: string | null; route: string | null; samples: number; configured: boolean }>;
  schedule: { everyDays: number; nextDueAt: string | null };
  runs: RunRow[];
  questions: QuestionRow[];
  sources: SourceRow[];
  pages: PageCheckRow[];
  traffic: TrafficWeek[];
}

interface QuestionDb {
  id: string; decision: string; prompt: string; keyword: string; branded: number;
  target_path: string | null; active: number; notes: string; sort: number;
}
interface RunDb {
  id: string; kind: string; status: string; created_at: string; finished_at: string | null; engines: string;
}
interface ResultDb {
  id: string; run_id: string; question_id: string; engine: EngineId; status: ResultLite["status"];
  finished_at: string | null; mentioned: number | null; cited: number | null; rank: number | null;
  own_url: string | null; brands: string; error: string | null; cost_usd: number;
}

const parseJson = <T>(s: string | null | undefined, fallback: T): T => {
  try {
    return s ? (JSON.parse(s) as T) : fallback;
  } catch {
    return fallback;
  }
};

const toLite = (r: ResultDb): ResultLite => ({
  runId: r.run_id,
  engine: r.engine,
  status: r.status,
  finishedAt: r.finished_at,
  mentioned: r.mentioned == null ? null : r.mentioned === 1,
  cited: r.cited == null ? null : r.cited === 1,
  rank: r.rank,
  ownUrl: r.own_url,
  brands: parseJson<string[]>(r.brands, []),
  error: r.error,
});

export function mondayOf(iso: string): string {
  const d = new Date(`${iso.slice(0, 10)}T00:00:00Z`);
  const back = (d.getUTCDay() + 6) % 7;
  return new Date(d.getTime() - back * 86_400_000).toISOString().slice(0, 10);
}

export async function loadSourceDecisions(db: D1Database) {
  const { results } = await db.prepare(
    "SELECT source_key, kind, status, next_step, url FROM ai_search_sources",
  ).all<{ source_key: string; kind: SourceKind; status: SourceStatus; next_step: string; url: string | null }>();
  return results ?? [];
}

export async function buildOverview(env: Env, now = new Date()): Promise<AiSearchOverview> {
  const db = env.DB;
  const since = new Date(now.getTime() - TRAFFIC_WEEKS * 7 * 86_400_000);
  const sinceIso = `${mondayOf(since.toISOString())}T00:00:00.000Z`;

  const [qRes, runRes, checkRes, visitRes, signupRes] = await db.batch([
    db.prepare(
      "SELECT id, decision, prompt, keyword, branded, target_path, active, notes, sort FROM ai_search_questions ORDER BY sort, id",
    ),
    db.prepare(
      `SELECT id, kind, status, created_at, finished_at, engines FROM ai_search_runs ORDER BY created_at DESC LIMIT ${RUN_HISTORY}`,
    ),
    // The latest check of each path.
    db.prepare(
      `SELECT c.path, c.checked_at, c.http_status, c.problems, c.words FROM ai_search_page_checks c
        WHERE c.checked_at = (SELECT MAX(c2.checked_at) FROM ai_search_page_checks c2 WHERE c2.path = c.path)`,
    ),
    db.prepare(
      `SELECT substr(created_at, 1, 10) AS d, type, referrer_host, utm_source, COUNT(*) AS n
         FROM site_events WHERE created_at >= ? GROUP BY d, type, referrer_host, utm_source`,
    ).bind(sinceIso),
    db.prepare(
      `SELECT substr(createdAt, 1, 10) AS d, signupReferrer, signupUtm, COUNT(*) AS n
         FROM user WHERE createdAt >= ? AND signupVia IS NOT NULL GROUP BY d, signupReferrer, signupUtm`,
    ).bind(sinceIso),
  ]);

  const questions = (qRes.results ?? []) as QuestionDb[];
  const runs = (runRes.results ?? []) as RunDb[];
  const runIds = runs.map((r) => r.id);

  let results: ResultDb[] = [];
  if (runIds.length) {
    const { results: rows } = await db.prepare(
      `SELECT id, run_id, question_id, engine, status, finished_at, mentioned, cited, rank, own_url, brands, error, cost_usd
         FROM ai_search_results WHERE run_id IN (${runIds.map(() => "?").join(",")})`,
    ).bind(...runIds).all<ResultDb>();
    results = rows ?? [];
  }

  // --- latest snapshot per question × engine: the newest run that answered it
  const runOrder = new Map(runIds.map((id, i) => [id, i])); // 0 = newest
  const byQE = new Map<string, Map<string, ResultDb[]>>(); // "q|e" → runId → rows
  for (const r of results) {
    const k = `${r.question_id}|${r.engine}`;
    let m = byQE.get(k);
    if (!m) byQE.set(k, (m = new Map()));
    const list = m.get(r.run_id) ?? [];
    list.push(r);
    m.set(r.run_id, list);
  }
  const latestRows = new Map<string, ResultDb[]>();
  for (const [k, m] of byQE) {
    const answeredRuns = [...m.entries()]
      .filter(([, rows]) => rows.some((r) => r.status === "ok" || r.status === "error"))
      .sort((a, b) => (runOrder.get(a[0]) ?? 0) - (runOrder.get(b[0]) ?? 0));
    if (answeredRuns.length) latestRows.set(k, answeredRuns[0][1]);
  }

  // --- sources behind those latest answers
  const latestIds = new Map<string, ResultDb>();
  for (const rows of latestRows.values()) for (const r of rows) if (r.status === "ok") latestIds.set(r.id, r);
  const latestRunIds = [...new Set([...latestIds.values()].map((r) => r.run_id))];
  let sourceRows: Array<{ result_id: string; position: number; domain: string; url: string }> = [];
  if (latestRunIds.length) {
    const { results: rows } = await db.prepare(
      `SELECT s.result_id, s.position, s.domain, s.url FROM ai_search_result_sources s
         JOIN ai_search_results r ON r.id = s.result_id
        WHERE r.run_id IN (${latestRunIds.map(() => "?").join(",")})`,
    ).bind(...latestRunIds).all<{ result_id: string; position: number; domain: string; url: string }>();
    sourceRows = (rows ?? []).filter((s) => latestIds.has(s.result_id));
  }

  const decisionsRaw = await loadSourceDecisions(db);
  const decisions = new Map<string, SourceDecision>(decisionsRaw.map((d) => [d.source_key, { key: d.source_key, kind: d.kind }]));

  // Aggregate per decision key (or domain when undecided).
  interface Agg { key: string; domain: string; kind: SourceKind; suggested: boolean; ai: number; g10: Set<string>; qs: Set<string>; es: Set<EngineId>; urls: Map<string, number> }
  const agg = new Map<string, Agg>();
  const perQuestion = new Map<string, Map<string, { count: number; kind: SourceKind }>>();
  for (const s of sourceRows) {
    const r = latestIds.get(s.result_id)!;
    const isGoogleOrganic = r.engine === "google" && s.position < OVERVIEW_POSITION_BASE;
    if (isGoogleOrganic && s.position > 10) continue;
    const c = classifySource(s.url, decisions);
    const key = c.key ?? s.domain;
    let a = agg.get(key);
    if (!a) agg.set(key, (a = { key, domain: s.domain, kind: c.kind, suggested: c.suggested, ai: 0, g10: new Set(), qs: new Set(), es: new Set(), urls: new Map() }));
    if (isGoogleOrganic) a.g10.add(r.question_id);
    else a.ai += 1;
    a.qs.add(r.question_id);
    a.es.add(r.engine);
    a.urls.set(s.url, (a.urls.get(s.url) ?? 0) + 1);
    if (!isGoogleOrganic && !isOwnUrl(s.url)) {
      let pq = perQuestion.get(r.question_id);
      if (!pq) perQuestion.set(r.question_id, (pq = new Map()));
      const cur = pq.get(s.domain) ?? { count: 0, kind: c.kind };
      cur.count += 1;
      pq.set(s.domain, cur);
    }
  }
  const decisionByKey = new Map(decisionsRaw.map((d) => [d.source_key, d]));
  const sources: SourceRow[] = [...agg.values()].map((a) => {
    const d = decisionByKey.get(a.key);
    return {
      key: a.key,
      domain: a.domain,
      kind: a.kind,
      suggested: a.suggested,
      status: d?.status ?? null,
      nextStep: d?.next_step || KIND_ACTIONS[a.kind],
      url: d?.url ?? null,
      aiCitations: a.ai,
      googleTop10: a.g10.size,
      questions: [...a.qs],
      engines: [...a.es],
      topUrls: [...a.urls.entries()].sort((x, y) => y[1] - x[1]).slice(0, 5).map(([u]) => u),
    };
  });
  // Decisions with nothing citing them right now still belong on the to-do list.
  for (const d of decisionsRaw) {
    if (agg.has(d.source_key)) continue;
    sources.push({
      key: d.source_key, domain: d.source_key.includes("/") ? new URL(d.source_key).hostname : d.source_key,
      kind: d.kind, suggested: false, status: d.status, nextStep: d.next_step || KIND_ACTIONS[d.kind], url: d.url,
      aiCitations: 0, googleTop10: 0, questions: [], engines: [], topUrls: [],
    });
  }
  sources.sort((x, y) => y.aiCitations - x.aiCitations || y.googleTop10 - x.googleTop10 || x.key.localeCompare(y.key));

  // --- crawl checks
  const pages: PageCheckRow[] = ((checkRes.results ?? []) as Array<{ path: string; checked_at: string; http_status: number | null; problems: string; words: number | null }>)
    .map((c) => ({ path: c.path, checkedAt: c.checked_at, httpStatus: c.http_status, problems: parseJson<string[]>(c.problems, []), words: c.words }));
  const pageByPath = new Map(pages.map((p) => [p.path, p]));

  // --- questions
  const branded = new Set(questions.filter((q) => q.branded === 1).map((q) => q.id));
  const questionRows: QuestionRow[] = questions.map((q) => {
    const latest: QuestionRow["latest"] = {};
    for (const e of ENGINE_IDS) {
      const rows = latestRows.get(`${q.id}|${e}`);
      const snap = rows ? snapshot(rows.map(toLite)) : null;
      if (snap) latest[e] = snap;
    }
    const cited = [...(perQuestion.get(q.id)?.entries() ?? [])]
      .map(([domain, v]) => ({ domain, count: v.count, kind: v.kind }))
      .sort((a, b) => b.count - a.count || a.domain.localeCompare(b.domain));
    const check = q.target_path ? pageByPath.get(q.target_path) : undefined;
    const history = runs
      .slice()
      .reverse()
      .map((run) => {
        const rows = results.filter((r) => r.run_id === run.id && r.question_id === q.id && r.engine !== "google" && r.status === "ok");
        const engines = [...new Set(rows.map((r) => r.engine))];
        if (!engines.length) return null;
        const perEngine = engines.map((e) => {
          const xs = rows.filter((r) => r.engine === e);
          return xs.filter((r) => r.mentioned === 1).length / xs.length;
        });
        return { runId: run.id, createdAt: run.created_at, mentionRate: perEngine.reduce((s, x) => s + x, 0) / perEngine.length };
      })
      .filter((h): h is NonNullable<typeof h> => h != null);
    return {
      id: q.id,
      decision: q.decision,
      prompt: q.prompt,
      keyword: q.keyword,
      branded: q.branded === 1,
      targetPath: q.target_path,
      active: q.active === 1,
      notes: q.notes,
      sort: q.sort,
      latest,
      diagnosis: diagnose({
        prompt: q.prompt,
        targetPath: q.target_path,
        snapshots: latest,
        pageProblems: check ? check.problems : null,
        citedSources: cited,
      }),
      history,
    };
  });

  // --- runs
  const runRows: RunRow[] = runs.map((run) => {
    const rows = results.filter((r) => r.run_id === run.id);
    return {
      id: run.id,
      kind: run.kind,
      status: run.status,
      createdAt: run.created_at,
      finishedAt: run.finished_at,
      engines: parseJson<EngineId[]>(run.engines, []),
      jobs: {
        total: rows.length,
        done: rows.filter((r) => r.status === "ok" || r.status === "error").length,
        failed: rows.filter((r) => r.status === "error").length,
      },
      costUsd: Math.round(rows.reduce((s, r) => s + (r.cost_usd ?? 0), 0) * 10_000) / 10_000,
      metrics: runMetrics(
        rows.map((r) => ({ questionId: r.question_id, engine: r.engine, status: r.status, mentioned: r.mentioned === 1, cited: r.cited === 1, rank: r.rank })),
        branded,
      ),
    };
  });

  // --- traffic: AI search vs Google, visits → downloads → sign-ups
  const weeks = new Map<string, TrafficWeek>();
  const week = (d: string) => {
    const w = mondayOf(d);
    let t = weeks.get(w);
    if (!t) weeks.set(w, (t = { week: w, aiVisits: 0, googleVisits: 0, aiDownloads: 0, googleDownloads: 0, aiSignups: 0, googleSignups: 0 }));
    return t;
  };
  for (let i = TRAFFIC_WEEKS - 1; i >= 0; i--) week(new Date(now.getTime() - i * 7 * 86_400_000).toISOString());
  for (const r of (visitRes.results ?? []) as Array<{ d: string; type: string; referrer_host: string | null; utm_source: string | null; n: number }>) {
    const src = classifyTraffic(r.referrer_host, r.utm_source);
    const isAi = src.kind === "ai";
    const isGoogle = src.id === "google";
    if (!isAi && !isGoogle) continue;
    const t = week(r.d);
    if (r.type === "visit") isAi ? (t.aiVisits += r.n) : (t.googleVisits += r.n);
    else if (r.type === "download") isAi ? (t.aiDownloads += r.n) : (t.googleDownloads += r.n);
  }
  for (const r of (signupRes.results ?? []) as Array<{ d: string; signupReferrer: string | null; signupUtm: string | null; n: number }>) {
    const src = classifyTraffic(r.signupReferrer, utmSourceOf(r.signupUtm));
    if (src.kind === "ai") week(r.d).aiSignups += r.n;
    else if (src.id === "google") week(r.d).googleSignups += r.n;
  }
  const minWeek = mondayOf(sinceIso);
  const traffic = [...weeks.values()].filter((w) => w.week >= minWeek).sort((a, b) => a.week.localeCompare(b.week)).slice(-TRAFFIC_WEEKS);

  // --- engines + schedule
  const everyDays = scheduleDays(env);
  const engines = ENGINES.map((e) => {
    const route = engineRoute(env, e.id);
    return { id: e.id, label: e.label, kind: e.kind, via: route?.via ?? null, route: route?.label ?? null, samples: e.samples, configured: !!route };
  });
  const lastRun = runs[0];
  const nextDueAt =
    everyDays === 0 || !engines.some((e) => e.configured)
      ? null
      : lastRun
        ? new Date(Date.parse(lastRun.created_at) + everyDays * 86_400_000).toISOString()
        : now.toISOString();

  return { engines, schedule: { everyDays, nextDueAt }, runs: runRows, questions: questionRows, sources, pages, traffic };
}

export interface QuestionDetail {
  question: QuestionRow | null;
  answers: Array<{
    id: string;
    runId: string;
    runCreatedAt: string;
    engine: EngineId;
    sample: number;
    status: string;
    finishedAt: string | null;
    model: string | null;
    mentioned: boolean | null;
    cited: boolean | null;
    rank: number | null;
    ownUrl: string | null;
    brands: string[];
    queries: string[];
    answer: string;
    costUsd: number;
    error: string | null;
    sources: Array<{ position: number; domain: string; url: string; title: string; kind: SourceKind; overview: boolean }>;
  }>;
}

/** One question's answers from its last three runs, full text and sources. */
export async function buildQuestionDetail(env: Env, id: string): Promise<QuestionDetail | null> {
  const db = env.DB;
  const q = await db.prepare("SELECT id FROM ai_search_questions WHERE id = ?").bind(id).first<{ id: string }>();
  if (!q) return null;
  const overview = await buildOverview(env);
  const { results: runs } = await db.prepare(
    `SELECT DISTINCT r.run_id AS id, ru.created_at FROM ai_search_results r JOIN ai_search_runs ru ON ru.id = r.run_id
      WHERE r.question_id = ? ORDER BY ru.created_at DESC LIMIT 3`,
  ).bind(id).all<{ id: string; created_at: string }>();
  const runIds = (runs ?? []).map((r) => r.id);
  if (!runIds.length) return { question: overview.questions.find((x) => x.id === id) ?? null, answers: [] };
  const ph = runIds.map(() => "?").join(",");
  const [resRows, srcRows] = await db.batch([
    db.prepare(
      `SELECT id, run_id, engine, sample, status, finished_at, model, mentioned, cited, rank, own_url, brands, queries, answer, cost_usd, error
         FROM ai_search_results WHERE question_id = ? AND run_id IN (${ph}) ORDER BY engine, sample`,
    ).bind(id, ...runIds),
    db.prepare(
      `SELECT s.result_id, s.position, s.domain, s.url, s.title FROM ai_search_result_sources s
         JOIN ai_search_results r ON r.id = s.result_id
        WHERE r.question_id = ? AND r.run_id IN (${ph}) ORDER BY s.position`,
    ).bind(id, ...runIds),
  ]);
  const decisions = new Map<string, SourceDecision>(
    (await loadSourceDecisions(db)).map((d) => [d.source_key, { key: d.source_key, kind: d.kind }]),
  );
  const created = new Map((runs ?? []).map((r) => [r.id, r.created_at]));
  const srcBy = new Map<string, QuestionDetail["answers"][number]["sources"]>();
  for (const s of (srcRows.results ?? []) as Array<{ result_id: string; position: number; domain: string; url: string; title: string }>) {
    const list = srcBy.get(s.result_id) ?? [];
    list.push({
      position: s.position, domain: s.domain, url: s.url, title: s.title,
      kind: classifySource(s.url, decisions).kind, overview: s.position > OVERVIEW_POSITION_BASE,
    });
    srcBy.set(s.result_id, list);
  }
  type Row = { id: string; run_id: string; engine: EngineId; sample: number; status: string; finished_at: string | null; model: string | null; mentioned: number | null; cited: number | null; rank: number | null; own_url: string | null; brands: string; queries: string; answer: string; cost_usd: number; error: string | null };
  const answers = ((resRows.results ?? []) as Row[])
    .map((r) => ({
      id: r.id,
      runId: r.run_id,
      runCreatedAt: created.get(r.run_id) ?? "",
      engine: r.engine,
      sample: r.sample,
      status: r.status,
      finishedAt: r.finished_at,
      model: r.model,
      mentioned: r.mentioned == null ? null : r.mentioned === 1,
      cited: r.cited == null ? null : r.cited === 1,
      rank: r.rank,
      ownUrl: r.own_url,
      brands: parseJson<string[]>(r.brands, []),
      queries: parseJson<string[]>(r.queries, []),
      answer: r.answer,
      costUsd: r.cost_usd,
      error: r.error,
      sources: srcBy.get(r.id) ?? [],
    }))
    .sort((a, b) => b.runCreatedAt.localeCompare(a.runCreatedAt) || ENGINE_IDS.indexOf(a.engine) - ENGINE_IDS.indexOf(b.engine) || a.sample - b.sample);
  return { question: overview.questions.find((x) => x.id === id) ?? null, answers };
}
