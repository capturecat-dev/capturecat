/**
 * Shapes of the API's Admin → AI search responses (apps/api
 * src/lib/ai-search/overview.ts). Kept by hand like the rest of this app's API
 * types; the API is the source of truth.
 */

export const ENGINE_IDS = ["chatgpt", "gemini", "perplexity", "claude", "google"] as const;
export type EngineId = (typeof ENGINE_IDS)[number];

export const SOURCE_KINDS = ["own", "claim", "earn", "contest", "competitor", "ignore"] as const;
export type SourceKind = (typeof SOURCE_KINDS)[number];

export const SOURCE_STATUSES = ["todo", "doing", "done"] as const;
export type SourceStatus = (typeof SOURCE_STATUSES)[number];

export interface EngineSnapshot {
  runId: string;
  checkedAt: string | null;
  samples: number;
  ok: number;
  mentionRate: number | null;
  citationRate: number | null;
  rank: number | null;
  ownUrl: string | null;
  topBrands: string[];
  error: string | null;
}

export type CauseCode = "crawl" | "missing_page" | "weak_page" | "third_party";

export interface Diagnosis {
  status: "winning" | "partial" | "losing" | "unmeasured";
  mentionRate: number | null;
  causes: Array<{ code: CauseCode; detail: string }>;
  action: string;
  topSources: Array<{ domain: string; count: number; kind: SourceKind }>;
}

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
  history: Array<{ runId: string; createdAt: string; mentionRate: number | null }>;
}

export interface RateTriple {
  mentionRate: number | null;
  citationRate: number | null;
  answers: number;
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
  metrics: RateTriple & { googleTop10: number | null; byEngine: Partial<Record<EngineId, RateTriple>> };
}

export interface SourceRow {
  key: string;
  domain: string;
  kind: SourceKind;
  suggested: boolean;
  status: SourceStatus | null;
  nextStep: string;
  url: string | null;
  aiCitations: number;
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
  week: string;
  aiVisits: number;
  googleVisits: number;
  aiDownloads: number;
  googleDownloads: number;
  aiSignups: number;
  googleSignups: number;
}

export interface AiSearchOverview {
  /** `via`/`route`: how the API asks the engine now; null = off. */
  engines: Array<{ id: EngineId; label: string; kind: "ai" | "search"; via: "dataforseo" | "gateway" | "gemini-key" | null; route: string | null; samples: number; configured: boolean }>;
  schedule: { everyDays: number; nextDueAt: string | null };
  runs: RunRow[];
  questions: QuestionRow[];
  sources: SourceRow[];
  pages: PageCheckRow[];
  traffic: TrafficWeek[];
}

export interface AnswerDetail {
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
}

export interface QuestionDetail {
  question: QuestionRow | null;
  answers: AnswerDetail[];
}

export const KIND_LABEL: Record<SourceKind, string> = {
  own: "Own",
  claim: "Claim",
  earn: "Earn",
  contest: "Contest",
  competitor: "Competitor",
  ignore: "Ignore",
};

export const KIND_HELP: Record<SourceKind, string> = {
  own: "Pages CaptureCat controls directly",
  claim: "Profiles and listings we can create or take over",
  earn: "Editorial mentions, reviews and discussions we have to deserve",
  contest: "Outdated or wrong information about CaptureCat to get corrected",
  competitor: "A competitor's own page",
  ignore: "Not worth acting on",
};

export const CAUSE_LABEL: Record<CauseCode, string> = {
  crawl: "Crawl / index",
  missing_page: "Missing page",
  weak_page: "Weak page",
  third_party: "Third-party sources",
};
