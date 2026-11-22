import { useState, type ReactNode } from "react";
import { toast } from "sonner";

import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Sheet, SheetContent, SheetDescription, SheetHeader, SheetTitle } from "@/components/ui/sheet";
import { Spinner } from "@/components/ui/spinner";
import { Switch } from "@/components/ui/switch";
import { Empty, KindBadge, StatusBadge, pct } from "@/components/admin/ai-search/ai-search-view";
import { trpc } from "@/lib/trpc/client";
import { CAUSE_LABEL, KIND_HELP, KIND_LABEL, SOURCE_KINDS, type AnswerDetail, type QuestionRow, type SourceKind, type SourceRow } from "@/lib/ai-search-types";
import { relativeTime } from "@/lib/format";
import { cn } from "@/lib/utils";

const ENGINE_LABEL: Record<string, string> = { chatgpt: "ChatGPT", gemini: "Gemini", perplexity: "Perplexity", claude: "Claude", google: "Google" };

const textareaCls =
  "w-full min-w-0 rounded-2xl border border-input bg-input/30 px-3 py-2 text-sm outline-none placeholder:text-muted-foreground focus-visible:border-ring focus-visible:ring-[3px] focus-visible:ring-ring/50";

function Field({ label, htmlFor, hint, children }: { label: string; htmlFor: string; hint?: ReactNode; children: ReactNode }) {
  return (
    <div className="space-y-1.5">
      <label htmlFor={htmlFor} className="text-sm font-medium">{label}</label>
      {children}
      {hint && <p className="text-xs text-muted-foreground">{hint}</p>}
    </div>
  );
}

/** One question: why it's won or lost, every answer from its last three runs, and its settings. */
export function QuestionSheet({ id, onClose }: { id: string; onClose: () => void }) {
  const { data, isLoading, error } = trpc.admin.aiSearchQuestion.useQuery({ id });
  const q = data?.question;
  const runs = [...new Set((data?.answers ?? []).map((a) => a.runId))];
  return (
    <Sheet open onOpenChange={(open) => !open && onClose()}>
      <SheetContent className="w-full overflow-y-auto data-[side=right]:sm:max-w-3xl">
        <SheetHeader>
          <SheetTitle className="pr-6">{q?.prompt ?? "Question"}</SheetTitle>
          <SheetDescription>
            {q ? (
              <>
                {q.decision} · Google: “{q.keyword}” · {q.targetPath ? <span className="font-mono">{q.targetPath}</span> : "no page yet"}
              </>
            ) : (
              "Loading…"
            )}
          </SheetDescription>
        </SheetHeader>
        {isLoading && (
          <div className="flex justify-center p-8">
            <Spinner />
          </div>
        )}
        {error && <p className="px-4 text-sm text-destructive">{error.message}</p>}
        {q && (
          <div className="flex flex-col divide-y px-4 pb-8">
            <section className="space-y-3 pb-6">
              <div className="flex items-center gap-2">
                <StatusBadge status={q.diagnosis.status} />
                <span className="text-sm text-muted-foreground">
                  Named in {pct(q.diagnosis.mentionRate)} of AI answers
                  {q.history.length > 1 && ` · was ${q.history.slice(0, -1).map((h) => pct(h.mentionRate)).join(" → ")}`}
                </span>
              </div>
              {q.diagnosis.causes.length > 0 && (
                <ul className="space-y-1 text-sm">
                  {q.diagnosis.causes.map((c) => (
                    <li key={c.code}>
                      <span className="font-medium">{CAUSE_LABEL[c.code]}:</span> <span className="text-muted-foreground">{c.detail}</span>
                    </li>
                  ))}
                </ul>
              )}
              <p className="rounded-lg bg-muted/50 px-3 py-2 text-sm">
                <span className="font-medium">Next change: </span>
                {q.diagnosis.action}
              </p>
            </section>

            <section className="space-y-4 py-6">
              <h3 className="text-sm font-medium">Answers</h3>
              {data!.answers.length === 0 && <Empty>Not asked yet.</Empty>}
              {runs.map((runId, i) => (
                <div key={runId} className="space-y-3">
                  <p className="text-xs uppercase tracking-wide text-muted-foreground">
                    {i === 0 ? "Latest run" : "Earlier run"} · {relativeTime(data!.answers.find((a) => a.runId === runId)?.runCreatedAt)}
                  </p>
                  {data!.answers.filter((a) => a.runId === runId).map((a) => (
                    <Answer key={a.id} a={a} defaultOpen={i === 0 && a.sample === 0} />
                  ))}
                </div>
              ))}
            </section>

            <section className="py-6">
              <QuestionForm question={q} />
            </section>
          </div>
        )}
      </SheetContent>
    </Sheet>
  );
}

function Answer({ a, defaultOpen }: { a: AnswerDetail; defaultOpen: boolean }) {
  const [open, setOpen] = useState(defaultOpen);
  const isGoogle = a.engine === "google";
  const organic = a.sources.filter((s) => !s.overview);
  const overview = a.sources.filter((s) => s.overview);
  return (
    <div className="rounded-xl border">
      <button type="button" className="flex w-full items-center justify-between gap-3 px-3 py-2 text-left" onClick={() => setOpen((v) => !v)}>
        <span className="flex items-center gap-2 text-sm">
          <span className="font-medium">{ENGINE_LABEL[a.engine] ?? a.engine}</span>
          {a.sample > 0 && <span className="text-xs text-muted-foreground">sample {a.sample + 1}</span>}
          {a.status === "error" ? (
            <Badge className="border-0 bg-destructive/10 text-destructive">error</Badge>
          ) : a.status !== "ok" ? (
            <Badge variant="outline">{a.status}</Badge>
          ) : isGoogle ? (
            <Badge variant="outline">{a.rank != null ? `capturecat.so #${a.rank}` : "not in top 20"}</Badge>
          ) : (
            <Badge className={cn("border-0", a.mentioned ? "bg-emerald-500/15 text-emerald-700 dark:text-emerald-400" : "bg-muted text-muted-foreground")}>
              {a.mentioned ? `named${a.rank ? ` #${a.rank}` : ""}` : "not named"}
            </Badge>
          )}
          {a.cited && <Badge className="border-0 bg-sky-500/15 text-sky-700 dark:text-sky-400">our page cited</Badge>}
        </span>
        <span className="text-xs text-muted-foreground">{a.model ?? ""}</span>
      </button>
      {open && (
        <div className="space-y-3 border-t px-3 py-3 text-sm">
          {a.error && <p className="text-destructive">{a.error}</p>}
          {a.brands.length > 0 && (
            <p className="text-xs text-muted-foreground">
              Named, in order: <span className="text-foreground">{a.brands.join(", ")}</span>
            </p>
          )}
          {a.answer && (
            <div className="max-h-80 overflow-y-auto whitespace-pre-wrap rounded-lg bg-muted/40 p-3 text-[13px] leading-relaxed">
              {isGoogle && <span className="mb-1 block text-xs font-medium text-muted-foreground">AI Overview</span>}
              {a.answer}
            </div>
          )}
          {a.queries.length > 0 && (
            <p className="text-xs text-muted-foreground">Searched: {a.queries.map((x) => `“${x}”`).join(", ")}</p>
          )}
          <SourceList title={isGoogle ? "Organic results" : "Cited sources"} sources={organic} />
          {overview.length > 0 && <SourceList title="AI Overview references" sources={overview} />}
        </div>
      )}
    </div>
  );
}

function SourceList({ title, sources }: { title: string; sources: AnswerDetail["sources"] }) {
  if (sources.length === 0) return null;
  return (
    <div className="space-y-1">
      <p className="text-xs font-medium text-muted-foreground">{title}</p>
      <ol className="space-y-1">
        {sources.map((s) => (
          <li key={`${s.position}-${s.url}`} className="flex items-center gap-2 text-xs">
            <span className="w-6 shrink-0 text-right tabular-nums text-muted-foreground">{s.overview ? "" : s.position}</span>
            <KindBadge kind={s.kind} />
            <a href={s.url} target="_blank" rel="noreferrer" className="min-w-0 truncate underline-offset-2 hover:underline" title={s.title || s.url}>
              {s.domain} <span className="text-muted-foreground">{s.title}</span>
            </a>
          </li>
        ))}
      </ol>
    </div>
  );
}

function QuestionForm({ question }: { question: QuestionRow }) {
  const utils = trpc.useUtils();
  const [form, setForm] = useState({
    decision: question.decision,
    prompt: question.prompt,
    keyword: question.keyword,
    targetPath: question.targetPath ?? "",
    notes: question.notes,
    branded: question.branded,
    active: question.active,
  });
  const update = trpc.admin.updateAiSearchQuestion.useMutation({
    onSuccess: () => {
      toast.success("Saved", { description: "Applies from the next run; earlier answers keep the wording they were asked with." });
      void utils.admin.aiSearch.invalidate();
      void utils.admin.aiSearchQuestion.invalidate({ id: question.id });
    },
    onError: (e) => toast.error(e.message),
  });
  const set = (patch: Partial<typeof form>) => setForm((f) => ({ ...f, ...patch }));
  const dirty =
    form.decision !== question.decision || form.prompt !== question.prompt || form.keyword !== question.keyword ||
    form.targetPath !== (question.targetPath ?? "") || form.notes !== question.notes || form.branded !== question.branded || form.active !== question.active;

  return (
    <form
      className="space-y-4"
      onSubmit={(e) => {
        e.preventDefault();
        update.mutate({ id: question.id, ...form, targetPath: form.targetPath.trim() || null });
      }}
    >
      <h3 className="text-sm font-medium">Question</h3>
      <QuestionFields form={form} set={set} idPrefix="edit" />
      <div className="flex items-center justify-between gap-4">
        <label className="flex items-center gap-2 text-sm">
          <Switch checked={form.active} onCheckedChange={(v) => set({ active: v })} />
          Asked in every run
        </label>
        <Button type="submit" disabled={!dirty || update.isPending}>
          {update.isPending ? "Saving…" : "Save"}
        </Button>
      </div>
    </form>
  );
}

interface QuestionFormValues {
  decision: string;
  prompt: string;
  keyword: string;
  targetPath: string;
  notes: string;
  branded: boolean;
}

function QuestionFields({ form, set, idPrefix, decisions }: { form: QuestionFormValues; set: (p: Partial<QuestionFormValues>) => void; idPrefix: string; decisions?: string[] }) {
  return (
    <>
      <Field label="Buyer decision" htmlFor={`${idPrefix}-decision`} hint="Groups the table. Questions that lead to the same choice share one.">
        <Input id={`${idPrefix}-decision`} list={`${idPrefix}-decisions`} value={form.decision} maxLength={120} onChange={(e) => set({ decision: e.target.value })} />
        {decisions && (
          <datalist id={`${idPrefix}-decisions`}>
            {decisions.map((d) => <option key={d} value={d} />)}
          </datalist>
        )}
      </Field>
      <Field label="AI prompt" htmlFor={`${idPrefix}-prompt`} hint={`${form.prompt.trim().length}/500 · asked word for word, the way a buyer would type it.`}>
        <textarea id={`${idPrefix}-prompt`} rows={2} className={textareaCls} value={form.prompt} maxLength={500} onChange={(e) => set({ prompt: e.target.value })} />
      </Field>
      <Field label="Google keyword" htmlFor={`${idPrefix}-keyword`} hint="The same decision as a search query.">
        <Input id={`${idPrefix}-keyword`} value={form.keyword} maxLength={200} onChange={(e) => set({ keyword: e.target.value })} />
      </Field>
      <Field label="Our page" htmlFor={`${idPrefix}-path`} hint="The capturecat.so path meant to answer it. Empty = no page yet (diagnosed as a missing page).">
        <Input id={`${idPrefix}-path`} className="font-mono" placeholder="/guides/…" value={form.targetPath} onChange={(e) => set({ targetPath: e.target.value })} />
      </Field>
      <Field label="Notes" htmlFor={`${idPrefix}-notes`}>
        <textarea id={`${idPrefix}-notes`} rows={2} className={textareaCls} value={form.notes} maxLength={2000} onChange={(e) => set({ notes: e.target.value })} />
      </Field>
      <label className="flex items-center gap-2 text-sm">
        <Switch checked={form.branded} onCheckedChange={(v) => set({ branded: v })} />
        Names CaptureCat (kept out of the non-branded rates)
      </label>
    </>
  );
}

export function QuestionDialog({ decisions, onClose }: { decisions: string[]; onClose: () => void }) {
  const utils = trpc.useUtils();
  const [form, setForm] = useState<QuestionFormValues>({ decision: decisions[0] ?? "", prompt: "", keyword: "", targetPath: "", notes: "", branded: false });
  const create = trpc.admin.createAiSearchQuestion.useMutation({
    onSuccess: () => {
      toast.success("Question added", { description: "It's asked from the next run." });
      void utils.admin.aiSearch.invalidate();
      onClose();
    },
    onError: (e) => toast.error(e.message),
  });
  const set = (patch: Partial<QuestionFormValues>) => setForm((f) => ({ ...f, ...patch }));
  const ready = form.decision.trim() && form.prompt.trim().length >= 5 && form.keyword.trim().length >= 2;
  return (
    <Dialog open onOpenChange={(open) => !open && onClose()}>
      <DialogContent className="sm:max-w-lg">
        <DialogHeader>
          <DialogTitle>Add a question</DialogTitle>
          <DialogDescription>Start from a decision a buyer makes, then write it the way they'd ask an AI and the way they'd search Google.</DialogDescription>
        </DialogHeader>
        <form
          id="add-question"
          className="space-y-4"
          onSubmit={(e) => {
            e.preventDefault();
            create.mutate({ ...form, targetPath: form.targetPath.trim() || null });
          }}
        >
          <QuestionFields form={form} set={set} idPrefix="add" decisions={decisions} />
        </form>
        <DialogFooter>
          <Button variant="outline" onClick={onClose}>Cancel</Button>
          <Button type="submit" form="add-question" disabled={!ready || create.isPending}>
            {create.isPending ? "Adding…" : "Add question"}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

export function SourceDialog({ source, onClose }: { source: SourceRow; onClose: () => void }) {
  const utils = trpc.useUtils();
  const [kind, setKind] = useState<SourceKind>(source.kind);
  const [nextStep, setNextStep] = useState(source.nextStep);
  const [url, setUrl] = useState(source.url ?? "");
  const save = trpc.admin.setAiSearchSource.useMutation({
    onSuccess: () => {
      void utils.admin.aiSearch.invalidate();
      onClose();
    },
    onError: (e) => toast.error(e.message),
  });
  return (
    <Dialog open onOpenChange={(open) => !open && onClose()}>
      <DialogContent className="sm:max-w-lg">
        <DialogHeader>
          <DialogTitle>{source.key}</DialogTitle>
          <DialogDescription>
            {source.aiCitations ? `Cited ${source.aiCitations}× in the latest answers` : "Not cited in the latest answers"}
            {source.googleTop10 ? ` · Google top 10 for ${source.googleTop10} keywords` : ""}.
          </DialogDescription>
        </DialogHeader>
        <form
          id="source-form"
          className="space-y-4"
          onSubmit={(e) => {
            e.preventDefault();
            save.mutate({ key: source.key, kind, nextStep: nextStep.trim(), url: url.trim() || null });
          }}
        >
          <div className="space-y-1.5">
            <span className="text-sm font-medium">Kind</span>
            <div className="flex flex-wrap gap-1.5" role="radiogroup" aria-label="Kind">
              {SOURCE_KINDS.map((k) => (
                <button
                  key={k}
                  type="button"
                  role="radio"
                  aria-checked={kind === k}
                  title={KIND_HELP[k]}
                  onClick={() => setKind(k)}
                  className={cn("rounded-full border px-3 py-1 text-xs", kind === k ? "border-foreground bg-secondary" : "text-muted-foreground hover:text-foreground")}
                >
                  {KIND_LABEL[k]}
                </button>
              ))}
            </div>
            <p className="text-xs text-muted-foreground">{KIND_HELP[kind]}</p>
          </div>
          <Field label="Next step" htmlFor="source-next">
            <textarea id="source-next" rows={2} className={textareaCls} maxLength={500} value={nextStep} onChange={(e) => setNextStep(e.target.value)} />
          </Field>
          <Field label="Our listing, profile or reply" htmlFor="source-url" hint="Once it exists.">
            <Input id="source-url" type="url" placeholder="https://" value={url} onChange={(e) => setUrl(e.target.value)} />
          </Field>
          {source.topUrls.length > 0 && (
            <div className="space-y-1">
              <p className="text-xs font-medium text-muted-foreground">Cited pages</p>
              {source.topUrls.map((u) => (
                <a key={u} href={u} target="_blank" rel="noreferrer" className="block truncate text-xs underline-offset-2 hover:underline">{u}</a>
              ))}
            </div>
          )}
        </form>
        <DialogFooter>
          <Button variant="outline" onClick={onClose}>Cancel</Button>
          <Button type="submit" form="source-form" disabled={save.isPending}>{save.isPending ? "Saving…" : "Save"}</Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
