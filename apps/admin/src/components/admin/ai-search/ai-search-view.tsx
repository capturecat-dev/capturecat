import { Fragment, useMemo, useState, type ReactNode } from "react";
import { ChevronRight, Play, Plus } from "lucide-react";
import { toast } from "sonner";

import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuLabel,
  DropdownMenuRadioGroup,
  DropdownMenuRadioItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { TableLoading } from "@/components/ui/table-loading";
import { DailyBars } from "@/components/admin/analytics/daily-bars";
import { QuestionDialog, QuestionSheet, SourceDialog } from "@/components/admin/ai-search/ai-search-detail";
import { trpc } from "@/lib/trpc/client";
import {
  CAUSE_LABEL,
  KIND_HELP,
  KIND_LABEL,
  SOURCE_KINDS,
  SOURCE_STATUSES,
  type AiSearchOverview,
  type Diagnosis,
  type EngineId,
  type EngineSnapshot,
  type QuestionRow,
  type SourceKind,
  type SourceRow,
  type SourceStatus,
} from "@/lib/ai-search-types";
import { formatNumber, plural, relativeTime } from "@/lib/format";
import { cn } from "@/lib/utils";

export const pct = (n: number | null | undefined) => (n == null ? "—" : `${Math.round(n * 100)}%`);

const STATUS_STYLE: Record<Diagnosis["status"], string> = {
  winning: "bg-emerald-500/15 text-emerald-700 dark:text-emerald-400",
  partial: "bg-amber-500/15 text-amber-700 dark:text-amber-400",
  losing: "bg-destructive/10 text-destructive",
  unmeasured: "bg-muted text-muted-foreground",
};
const STATUS_LABEL: Record<Diagnosis["status"], string> = {
  winning: "Winning",
  partial: "Partial",
  losing: "Losing",
  unmeasured: "Not measured",
};

export function StatusBadge({ status }: { status: Diagnosis["status"] }) {
  return <Badge className={cn("border-0", STATUS_STYLE[status])}>{STATUS_LABEL[status]}</Badge>;
}

const KIND_STYLE: Record<SourceKind, string> = {
  own: "bg-sky-500/15 text-sky-700 dark:text-sky-400",
  claim: "bg-violet-500/15 text-violet-700 dark:text-violet-400",
  earn: "bg-amber-500/15 text-amber-700 dark:text-amber-400",
  contest: "bg-destructive/10 text-destructive",
  competitor: "bg-muted text-foreground",
  ignore: "bg-muted text-muted-foreground",
};

export function KindBadge({ kind, suggested }: { kind: SourceKind; suggested?: boolean }) {
  return (
    <Badge className={cn("border-0", KIND_STYLE[kind], suggested && "opacity-70")} title={KIND_HELP[kind] + (suggested ? " (suggested)" : "")}>
      {KIND_LABEL[kind]}
      {suggested ? "?" : ""}
    </Badge>
  );
}

/**
 * One stacked surface with hairline sections, like Analytics: where we stand,
 * the questions (the work list), the sources behind the answers, the crawl
 * check of our pages, and the traffic that tells us whether any of it moved.
 */
export function AiSearchBody() {
  const utils = trpc.useUtils();
  const { data, isLoading, error } = trpc.admin.aiSearch.useQuery(undefined, {
    // While a run is draining, the page follows it.
    refetchInterval: (q) => (q.state.data?.runs[0]?.status === "running" ? 15_000 : false),
  });
  const [openQuestion, setOpenQuestion] = useState<string | null>(null);
  const [adding, setAdding] = useState(false);

  const start = trpc.admin.startAiSearchRun.useMutation({
    onSuccess: (r) => {
      toast.success("Run started", {
        description: `${plural(r.jobs, "answer")} queued. The first arrive within a minute; the rest every five minutes.`,
      });
      void utils.admin.aiSearch.invalidate();
    },
    onError: (e) => toast.error(e.message),
  });

  if (isLoading) return <TableLoading />;
  if (error || !data) return <p className="text-sm text-destructive">{error?.message ?? "Could not load AI search."}</p>;

  const running = data.runs[0]?.status === "running" ? data.runs[0] : null;
  const anyEngine = data.engines.some((e) => e.configured);

  return (
    <div className="flex flex-col divide-y">
      <section className="flex flex-col gap-4 pb-6 sm:flex-row sm:items-start sm:justify-between">
        <Engines data={data} />
        <div className="flex shrink-0 flex-col items-start gap-2 sm:items-end">
          <Button onClick={() => start.mutate()} disabled={!anyEngine || !!running || start.isPending}>
            <Play className="size-4" />
            {running ? `Running · ${running.jobs.done}/${running.jobs.total}` : "Run now"}
          </Button>
          <span className="text-xs text-muted-foreground">
            {data.schedule.everyDays === 0
              ? "Schedule off"
              : data.schedule.nextDueAt
                ? `Every ${plural(data.schedule.everyDays, "day")} · next ${dueLabel(data.schedule.nextDueAt)}`
                : "Scheduled once an engine is configured"}
          </span>
        </div>
      </section>

      <Kpis data={data} />

      <Section
        title="Questions"
        note="Grouped by the buyer decision behind them. Cells show how often CaptureCat was named, if our page was cited (●), and our place in the answer; Google shows our organic rank."
        action={
          <Button variant="outline" size="sm" onClick={() => setAdding(true)}>
            <Plus className="size-4" /> Add question
          </Button>
        }
      >
        <Questions data={data} onOpen={setOpenQuestion} />
      </Section>

      <Section
        title="Sources behind the answers"
        note="What the latest answers cited (AI engines and Google's AI Overview) and who holds Google's top 10. Own: our pages. Claim: listings we can create. Earn: coverage and discussions we have to deserve. Contest: wrong facts to correct. A ? marks a suggestion nobody has confirmed."
      >
        <Sources data={data} />
      </Section>

      <Section title="Our pages" note="The crawl/index check of every target page, taken when each run starts.">
        <Pages data={data} />
      </Section>

      <Section
        title="Did it move users?"
        note="Weekly, UTC, from the site's own cookieless events: AI search (ChatGPT, Claude, Perplexity, Gemini, …) and Google measured apart. Sign-ups from the Mac app carry no source."
      >
        <Traffic data={data} />
      </Section>

      <Section title="Runs" note="Rates count non-branded questions only, each once per engine.">
        <Runs data={data} />
      </Section>

      {openQuestion && <QuestionSheet id={openQuestion} onClose={() => setOpenQuestion(null)} />}
      {adding && <QuestionDialog decisions={[...new Set(data.questions.map((q) => q.decision))]} onClose={() => setAdding(false)} />}
    </div>
  );
}

function dueLabel(iso: string): string {
  const t = Date.parse(iso);
  if (t <= Date.now()) return "within the hour";
  return new Date(t).toLocaleDateString("en-US", { weekday: "short", month: "short", day: "numeric" });
}

function Section({ title, note, action, children }: { title: string; note?: string; action?: ReactNode; children: ReactNode }) {
  return (
    <section className="py-6">
      <div className="mb-4 flex items-start justify-between gap-4">
        <div className="space-y-1">
          <h2 className="text-base font-medium">{title}</h2>
          {note && <p className="max-w-3xl text-xs text-muted-foreground">{note}</p>}
        </div>
        {action}
      </div>
      {children}
    </section>
  );
}

function Stat({ label, value, sub }: { label: string; value: string; sub?: string }) {
  return (
    <div className="flex flex-col gap-1">
      <span className="text-xs text-muted-foreground">{label}</span>
      <span className="text-2xl font-semibold tabular-nums tracking-tight">{value}</span>
      {sub && <span className="text-xs text-muted-foreground">{sub}</span>}
    </div>
  );
}

function Engines({ data }: { data: AiSearchOverview }) {
  return (
    <div className="flex flex-wrap gap-2">
      {data.engines.map((e) => (
        <span
          key={e.id}
          className={cn(
            "inline-flex items-center gap-1.5 rounded-full border px-3 py-1 text-xs",
            e.configured ? "text-foreground" : "border-dashed text-muted-foreground",
          )}
          title={
            e.configured
              ? `${e.route} · ${e.samples > 1 ? `asked ${e.samples}× per run` : "asked once per run"}`
              : "Off: needs DATAFORSEO_LOGIN and DATAFORSEO_PASSWORD on the API Worker, and credit on the DataForSEO account"
          }
        >
          <span className={cn("size-1.5 rounded-full", e.configured ? "bg-emerald-500" : "bg-muted-foreground/40")} />
          {e.label}
          {e.via === "gateway" && <span className="text-muted-foreground">· AI Gateway</span>}
          {e.via === "dataforseo" && <span className="text-muted-foreground">· app</span>}
          {!e.configured && <span className="text-muted-foreground">· off</span>}
        </span>
      ))}
    </div>
  );
}

function Kpis({ data }: { data: AiSearchOverview }) {
  const finished = data.runs.filter((r) => r.status === "done" && r.metrics.answers > 0);
  const [last, prev] = finished;
  const delta = (a: number | null | undefined, b: number | null | undefined) =>
    a == null || b == null ? undefined : `${a - b >= 0 ? "+" : "−"}${Math.abs(Math.round((a - b) * 100))} pts vs previous run`;
  const active = data.questions.filter((q) => q.active);
  const counts = { winning: 0, partial: 0, losing: 0, unmeasured: 0 };
  for (const q of active) counts[q.diagnosis.status]++;
  const weeks = data.traffic.slice(-4);
  const sum = (k: keyof AiSearchOverview["traffic"][number]) => weeks.reduce((s, w) => s + (w[k] as number), 0);
  return (
    <section className="py-6">
      <div className="grid grid-cols-2 gap-x-8 gap-y-6 sm:grid-cols-3 xl:grid-cols-6">
        <Stat label="Named by AI · non-branded" value={pct(last?.metrics.mentionRate)} sub={delta(last?.metrics.mentionRate, prev?.metrics.mentionRate) ?? (last ? `${plural(last.metrics.answers, "question")} × engine` : "No run yet")} />
        <Stat label="Our page cited" value={pct(last?.metrics.citationRate)} sub={delta(last?.metrics.citationRate, prev?.metrics.citationRate)} />
        <Stat label="Google top 10" value={pct(last?.metrics.googleTop10)} sub={last?.metrics.googleTop10 == null ? "Needs the Google engine" : delta(last?.metrics.googleTop10, prev?.metrics.googleTop10)} />
        <Stat label="Questions" value={`${counts.winning}/${active.length}`} sub={`winning · ${counts.partial} partial · ${counts.losing} losing`} />
        <Stat label="AI search visits · 4 wks" value={formatNumber(sum("aiVisits"))} sub={`${plural(sum("aiSignups"), "sign-up")} · Google ${formatNumber(sum("googleVisits"))} visits`} />
        <Stat label="Last run" value={last ? relativeTime(last.finishedAt ?? last.createdAt) : "—"} sub={last ? `$${last.costUsd.toFixed(2)} · ${plural(last.engines.length, "engine")}` : undefined} />
      </div>
    </section>
  );
}

function EngineCell({ engine, s }: { engine: EngineId; s: EngineSnapshot | undefined }) {
  if (!s) return <span className="text-muted-foreground/50">·</span>;
  if (s.ok === 0) return <span className="text-xs text-destructive" title={s.error ?? "Failed"}>error</span>;
  if (engine === "google") {
    return (
      <span className={cn("tabular-nums", s.rank != null && s.rank <= 10 ? "font-medium" : "text-muted-foreground")} title={s.ownUrl ?? "Not in the top 20"}>
        {s.rank != null ? `#${s.rank}` : "—"}
        {(s.citationRate ?? 0) > 0 && <span className="ml-1 text-sky-500" title="Cited in the AI Overview">●</span>}
      </span>
    );
  }
  const named = Math.round((s.mentionRate ?? 0) * s.ok);
  return (
    <span
      className={cn("tabular-nums", named === 0 ? "text-muted-foreground" : named * 2 >= s.ok ? "font-medium text-emerald-600 dark:text-emerald-400" : "text-amber-600 dark:text-amber-400")}
      title={`Named in ${named} of ${s.ok} answers${s.rank ? ` · best place #${s.rank}` : ""}${s.topBrands.length ? ` · also named: ${s.topBrands.join(", ")}` : ""}`}
    >
      {named}/{s.ok}
      {(s.citationRate ?? 0) > 0 && <span className="ml-1 text-sky-500">●</span>}
      {s.rank != null && <span className="ml-1 text-xs text-muted-foreground">#{s.rank}</span>}
    </span>
  );
}

function Questions({ data, onOpen }: { data: AiSearchOverview; onOpen: (id: string) => void }) {
  const engines = data.engines.filter((e) => e.configured || data.questions.some((q) => q.latest[e.id]));
  const [showRetired, setShowRetired] = useState(false);
  const groups = useMemo(() => {
    const m = new Map<string, QuestionRow[]>();
    for (const q of data.questions) {
      if (!q.active && !showRetired) continue;
      m.set(q.decision, [...(m.get(q.decision) ?? []), q]);
    }
    return [...m.entries()];
  }, [data.questions, showRetired]);
  const retired = data.questions.filter((q) => !q.active).length;

  return (
    <div className="flex flex-col gap-3">
      <div className="overflow-x-auto">
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead className="min-w-[22rem]">Question</TableHead>
              {engines.map((e) => (
                <TableHead key={e.id} className="text-right">{e.label}</TableHead>
              ))}
              <TableHead>Status</TableHead>
              <TableHead className="min-w-[18rem]">Why, and the next change</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {groups.map(([decision, qs]) => (
              <Fragment key={decision}>
                <TableRow className="hover:bg-transparent">
                  <TableCell colSpan={engines.length + 3} className="pt-5 text-xs font-medium uppercase tracking-wide text-muted-foreground">
                    {decision}
                  </TableCell>
                </TableRow>
                {qs.map((q) => (
                  <TableRow key={q.id} className={cn("cursor-pointer", !q.active && "opacity-50")} onClick={() => onOpen(q.id)}>
                    <TableCell className="align-top whitespace-normal">
                      <div className="flex items-start gap-1">
                        <span className="font-medium">{q.prompt}</span>
                        <ChevronRight className="mt-0.5 size-4 shrink-0 text-muted-foreground" />
                      </div>
                      <div className="mt-1 text-xs text-muted-foreground">
                        Google: “{q.keyword}” ·{" "}
                        {q.targetPath ? <span className="font-mono">{q.targetPath}</span> : <span className="text-amber-600 dark:text-amber-400">no page</span>}
                        {q.branded && " · branded"}
                        {!q.active && " · retired"}
                      </div>
                    </TableCell>
                    {engines.map((e) => (
                      <TableCell key={e.id} className="text-right align-top">
                        <EngineCell engine={e.id} s={q.latest[e.id]} />
                      </TableCell>
                    ))}
                    <TableCell className="align-top">
                      <StatusBadge status={q.diagnosis.status} />
                    </TableCell>
                    <TableCell className="align-top whitespace-normal text-sm">
                      {q.diagnosis.causes.length > 0 && (
                        <div className="mb-1 flex flex-wrap gap-1">
                          {q.diagnosis.causes.map((c) => (
                            <Badge key={c.code} variant="outline" title={c.detail}>{CAUSE_LABEL[c.code]}</Badge>
                          ))}
                        </div>
                      )}
                      <span className="text-muted-foreground">{q.diagnosis.action}</span>
                    </TableCell>
                  </TableRow>
                ))}
              </Fragment>
            ))}
          </TableBody>
        </Table>
      </div>
      {retired > 0 && (
        <button type="button" className="self-start text-xs text-muted-foreground underline underline-offset-2 hover:text-foreground" onClick={() => setShowRetired((v) => !v)}>
          {showRetired ? "Hide" : "Show"} {plural(retired, "retired question")}
        </button>
      )}
    </div>
  );
}

const KIND_FILTERS: Array<SourceKind | "all"> = ["all", "claim", "earn", "contest", "own", "competitor", "ignore"];

function Sources({ data }: { data: AiSearchOverview }) {
  const [filter, setFilter] = useState<SourceKind | "all">("all");
  const [editing, setEditing] = useState<SourceRow | null>(null);
  const utils = trpc.useUtils();
  const save = trpc.admin.setAiSearchSource.useMutation({
    onSuccess: () => utils.admin.aiSearch.invalidate(),
    onError: (e) => toast.error(e.message),
  });
  const rows = data.sources.filter((s) => (filter === "all" ? s.kind !== "ignore" : s.kind === filter));
  const count = (k: SourceKind | "all") => (k === "all" ? data.sources.filter((s) => s.kind !== "ignore").length : data.sources.filter((s) => s.kind === k).length);
  const qPrompt = new Map(data.questions.map((q) => [q.id, q.prompt]));

  if (data.sources.length === 0) return <Empty>No sources yet: they come from the first run's answers.</Empty>;
  return (
    <div className="flex flex-col gap-3">
      <div className="inline-flex flex-wrap gap-1 self-start rounded-lg border p-0.5" role="radiogroup" aria-label="Kind">
        {KIND_FILTERS.map((k) => (
          <button
            key={k}
            type="button"
            role="radio"
            aria-checked={filter === k}
            onClick={() => setFilter(k)}
            className={cn("rounded-md px-3 py-1 text-sm", filter === k ? "bg-secondary text-secondary-foreground" : "text-muted-foreground hover:text-foreground")}
          >
            {k === "all" ? "All" : KIND_LABEL[k]} <span className="tabular-nums text-muted-foreground">{count(k)}</span>
          </button>
        ))}
      </div>
      <div className="overflow-x-auto">
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>Source</TableHead>
              <TableHead>Kind</TableHead>
              <TableHead>Status</TableHead>
              <TableHead className="text-right" title="Times cited by AI engines (and Google's AI Overview) in the latest answers">AI cites</TableHead>
              <TableHead className="text-right" title="Keywords where it holds a Google top-10 result">Google top 10</TableHead>
              <TableHead className="min-w-[18rem]">Next step</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {rows.map((s) => (
              <TableRow key={s.key}>
                <TableCell className="align-top whitespace-normal">
                  <div className="font-medium">{s.key}</div>
                  {s.questions.length > 0 && (
                    <div className="mt-0.5 text-xs text-muted-foreground" title={s.questions.map((id) => qPrompt.get(id) ?? id).join("\n")}>
                      {plural(s.questions.length, "question")} · {s.engines.join(", ")}
                    </div>
                  )}
                  {s.topUrls[0] && (
                    <a href={s.topUrls[0]} target="_blank" rel="noreferrer" className="mt-0.5 block max-w-[24rem] truncate text-xs text-muted-foreground underline-offset-2 hover:underline">
                      {s.topUrls[0]}
                    </a>
                  )}
                </TableCell>
                <TableCell className="align-top">
                  <DropdownMenu>
                    <DropdownMenuTrigger className="rounded-full outline-none focus-visible:ring-2 focus-visible:ring-ring">
                      <KindBadge kind={s.kind} suggested={s.suggested} />
                    </DropdownMenuTrigger>
                    <DropdownMenuContent align="start">
                      <DropdownMenuLabel>Kind of source</DropdownMenuLabel>
                      <DropdownMenuSeparator />
                      <DropdownMenuRadioGroup
                        value={s.suggested ? "" : s.kind}
                        onValueChange={(v) => save.mutate({ key: s.key, kind: v as SourceKind })}
                      >
                        {SOURCE_KINDS.map((k) => (
                          <DropdownMenuRadioItem key={k} value={k}>
                            <span className="flex flex-col">
                              <span>{KIND_LABEL[k]}</span>
                              <span className="text-xs text-muted-foreground">{KIND_HELP[k]}</span>
                            </span>
                          </DropdownMenuRadioItem>
                        ))}
                      </DropdownMenuRadioGroup>
                    </DropdownMenuContent>
                  </DropdownMenu>
                </TableCell>
                <TableCell className="align-top">
                  <DropdownMenu>
                    <DropdownMenuTrigger className="rounded-full outline-none focus-visible:ring-2 focus-visible:ring-ring">
                      <Badge variant={s.status === "done" ? "secondary" : "outline"}>{s.status ?? "—"}</Badge>
                    </DropdownMenuTrigger>
                    <DropdownMenuContent align="start">
                      <DropdownMenuRadioGroup
                        value={s.status ?? ""}
                        onValueChange={(v) => save.mutate({ key: s.key, kind: s.kind, status: v as SourceStatus })}
                      >
                        {SOURCE_STATUSES.map((st) => (
                          <DropdownMenuRadioItem key={st} value={st}>{st}</DropdownMenuRadioItem>
                        ))}
                      </DropdownMenuRadioGroup>
                    </DropdownMenuContent>
                  </DropdownMenu>
                </TableCell>
                <TableCell className="text-right align-top tabular-nums">{s.aiCitations || "—"}</TableCell>
                <TableCell className="text-right align-top tabular-nums">{s.googleTop10 || "—"}</TableCell>
                <TableCell className="align-top whitespace-normal text-sm">
                  <button type="button" className="text-left text-muted-foreground hover:text-foreground" onClick={() => setEditing(s)}>
                    {s.nextStep || "Add a next step"}
                  </button>
                  {s.url && (
                    <a href={s.url} target="_blank" rel="noreferrer" className="mt-0.5 block max-w-[24rem] truncate text-xs underline underline-offset-2">
                      {s.url}
                    </a>
                  )}
                </TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      </div>
      {editing && <SourceDialog source={editing} onClose={() => setEditing(null)} />}
    </div>
  );
}

function Pages({ data }: { data: AiSearchOverview }) {
  if (data.pages.length === 0) return <Empty>Checked when the first run starts.</Empty>;
  const bad = data.pages.filter((p) => p.problems.length > 0);
  return (
    <div className="flex flex-col gap-3">
      <p className="text-sm">
        {bad.length === 0 ? `All ${data.pages.length} target pages look healthy.` : `${plural(bad.length, "page")} of ${data.pages.length} with a problem.`}{" "}
        <span className="text-muted-foreground">
          Checked {relativeTime(data.pages[0]?.checkedAt)}. Cloudflare's AI-crawler blocking can't be seen from here; check AI Crawl Control in the dashboard.
        </span>
      </p>
      {bad.length > 0 && (
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>Page</TableHead>
              <TableHead className="text-right">HTTP</TableHead>
              <TableHead className="text-right">Words</TableHead>
              <TableHead>Problems</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {bad.map((p) => (
              <TableRow key={p.path}>
                <TableCell className="font-mono text-xs">
                  <a href={`https://capturecat.so${p.path}`} target="_blank" rel="noreferrer" className="underline-offset-2 hover:underline">{p.path}</a>
                </TableCell>
                <TableCell className="text-right tabular-nums">{p.httpStatus ?? "—"}</TableCell>
                <TableCell className="text-right tabular-nums">{p.words ?? "—"}</TableCell>
                <TableCell className="whitespace-normal text-sm text-destructive">{p.problems.join("; ")}</TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      )}
    </div>
  );
}

function Traffic({ data }: { data: AiSearchOverview }) {
  const pts = (k: keyof AiSearchOverview["traffic"][number]) => data.traffic.map((w) => ({ day: w.week, value: w[k] as number }));
  return (
    <div className="grid gap-8 sm:grid-cols-2 xl:grid-cols-4">
      <DailyBars title="AI search visits" points={pts("aiVisits")} />
      <DailyBars title="AI search sign-ups" points={pts("aiSignups")} />
      <DailyBars title="Google visits" points={pts("googleVisits")} />
      <DailyBars title="Google sign-ups" points={pts("googleSignups")} />
    </div>
  );
}

function Runs({ data }: { data: AiSearchOverview }) {
  if (data.runs.length === 0) return <Empty>No runs yet.</Empty>;
  const engines = data.engines.filter((e) => data.runs.some((r) => r.engines.includes(e.id)));
  return (
    <div className="overflow-x-auto">
      <Table>
        <TableHeader>
          <TableRow>
            <TableHead>Started</TableHead>
            <TableHead>Answers</TableHead>
            <TableHead className="text-right">Named</TableHead>
            <TableHead className="text-right">Cited</TableHead>
            {engines.map((e) => (
              <TableHead key={e.id} className="text-right">{e.label}</TableHead>
            ))}
            <TableHead className="text-right">Cost</TableHead>
          </TableRow>
        </TableHeader>
        <TableBody>
          {data.runs.map((r) => (
            <TableRow key={r.id}>
              <TableCell>
                {new Date(r.createdAt).toLocaleString("en-US", { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" })}
                <span className="ml-2 text-xs text-muted-foreground">{r.kind === "manual" ? "manual" : "scheduled"}</span>
              </TableCell>
              <TableCell className="tabular-nums">
                {r.jobs.done}/{r.jobs.total}
                {r.jobs.failed > 0 && <span className="ml-1 text-xs text-destructive">{r.jobs.failed} failed</span>}
                {r.status === "running" && <span className="ml-1 text-xs text-muted-foreground">running</span>}
              </TableCell>
              <TableCell className="text-right tabular-nums">{pct(r.metrics.mentionRate)}</TableCell>
              <TableCell className="text-right tabular-nums">{pct(r.metrics.citationRate)}</TableCell>
              {engines.map((e) => (
                <TableCell key={e.id} className="text-right tabular-nums text-muted-foreground">
                  {e.id === "google" ? pct(r.metrics.googleTop10) : pct(r.metrics.byEngine[e.id]?.mentionRate)}
                </TableCell>
              ))}
              <TableCell className="text-right tabular-nums">${r.costUsd.toFixed(2)}</TableCell>
            </TableRow>
          ))}
        </TableBody>
      </Table>
    </div>
  );
}

export function Empty({ children }: { children: ReactNode }) {
  return <p className="text-sm text-muted-foreground">{children}</p>;
}
