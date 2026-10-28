import { useState } from "react";
import { ExternalLink, MoreHorizontal, Newspaper, Plus, Trash2 } from "lucide-react";
import { toast } from "sonner";

import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { Input } from "@/components/ui/input";
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from "@/components/ui/alert-dialog";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { Empty, EmptyContent, EmptyDescription, EmptyHeader, EmptyMedia, EmptyTitle } from "@/components/ui/empty";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { TableLoading } from "@/components/ui/table-loading";
import { Field, Section } from "@/components/admin/plans-table";
import { trpc } from "@/lib/trpc/client";
import {
  CATEGORY_META,
  CHANGELOG_LIMITS,
  CHANGELOG_PLATFORMS,
  PLATFORM_LABELS,
  cleanSlugInput,
  contentChanged,
  emptyChangelogForm,
  formFromEntry,
  formProblem,
  inputFromForm,
  isDirty,
  isFutureDay,
  isoDay,
  previewEntry,
  publishDate,
  slugify,
  statusLine,
  togglePlatform,
  versionLabel,
  withTitle,
  type AdminChangelogEntry,
  type ChangelogCategory,
  type ChangelogForm,
} from "@/lib/changelog-form";
// The public site's own entry renderer — the preview IS the page's code.
import { ChangelogEntryView } from "../../../../web/src/lib/changelog/entry-view";

/** Where published entries live (links out of the console). */
const PUBLIC_SITE = "https://capturecat.so";
const CATEGORIES = Object.keys(CATEGORY_META) as ChangelogCategory[];

export function ChangelogTable() {
  const { data, isLoading, error } = trpc.admin.listChangelog.useQuery();
  // null = closed; "new" = creating; otherwise the id being edited.
  const [editing, setEditing] = useState<string | null>(null);

  if (isLoading) return <TableLoading />;
  const entries = data?.entries ?? [];
  const editingEntry = editing && editing !== "new" ? entries.find((e) => e.id === editing) ?? null : null;
  const drafts = entries.filter((e) => e.status === "draft").length;

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <p className="text-sm text-muted-foreground">
          {entries.length === 0
            ? "Nothing written yet."
            : `${entries.length - drafts} published or scheduled · ${drafts} draft${drafts === 1 ? "" : "s"}`}
        </p>
        <div className="flex flex-wrap items-center gap-2">
          <Button size="sm" variant="outline" asChild>
            <a href={`${PUBLIC_SITE}/changelog`} target="_blank" rel="noopener noreferrer">
              <ExternalLink className="mr-1 h-4 w-4" /> View page
            </a>
          </Button>
          <Button size="sm" onClick={() => setEditing("new")}>
            <Plus className="mr-1 h-4 w-4" /> New entry
          </Button>
        </div>
      </div>

      {error && <p className="text-sm text-destructive">{error.message}</p>}

      {entries.length === 0 && !error ? (
        <Empty className="border">
          <EmptyHeader>
            <EmptyMedia variant="icon">
              <Newspaper />
            </EmptyMedia>
            <EmptyTitle>No entries yet</EmptyTitle>
            <EmptyDescription>
              Write the first one. It stays a draft, visible only here, until you publish it.
            </EmptyDescription>
          </EmptyHeader>
          <EmptyContent>
            <Button size="sm" onClick={() => setEditing("new")}>
              <Plus className="mr-1 h-4 w-4" /> New entry
            </Button>
          </EmptyContent>
        </Empty>
      ) : (
        entries.length > 0 && (
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Entry</TableHead>
                <TableHead>Category</TableHead>
                <TableHead>Platforms</TableHead>
                <TableHead>Version</TableHead>
                <TableHead>Status</TableHead>
                <TableHead className="w-10" />
              </TableRow>
            </TableHeader>
            <TableBody>
              {entries.map((entry) => (
                <EntryRow key={entry.id} entry={entry} onEdit={() => setEditing(entry.id)} />
              ))}
            </TableBody>
          </Table>
        )
      )}

      {editing && <ChangelogEditorDialog key={editing} entry={editingEntry} onClose={() => setEditing(null)} />}
    </div>
  );
}

export function CategoryBadge({ category }: { category: ChangelogCategory }) {
  const meta = CATEGORY_META[category] ?? CATEGORY_META.new;
  return (
    <span className={`inline-flex h-5 items-center rounded-full border px-2 text-xs font-medium ${meta.badge}`}>{meta.label}</span>
  );
}

export function StatusBadge({ entry }: { entry: Pick<AdminChangelogEntry, "status" | "publishedAt"> }) {
  if (entry.status === "draft") return <Badge variant="outline">Draft</Badge>;
  return (
    <span className="inline-flex flex-wrap items-center gap-1.5">
      <Badge variant={entry.status === "published" ? "default" : "secondary"}>
        {entry.status === "published" ? "Published" : "Scheduled"}
      </Badge>
      <span className="text-xs text-muted-foreground">{statusLine(entry).replace(/^(Published|Scheduled for) /, "")}</span>
    </span>
  );
}

function EntryRow({ entry, onEdit }: { entry: AdminChangelogEntry; onEdit: () => void }) {
  const utils = trpc.useUtils();
  const [confirmDelete, setConfirmDelete] = useState(false);
  const refresh = () => utils.admin.listChangelog.invalidate();
  const publish = trpc.admin.publishChangelogEntry.useMutation({
    onSuccess: ({ entry: e }) => {
      refresh();
      toast.success(e.status === "scheduled" ? statusLine(e) : "Published", { description: `${PUBLIC_SITE}/changelog/${e.slug}` });
    },
    onError: (e) => toast.error(e.message),
  });
  const unpublish = trpc.admin.unpublishChangelogEntry.useMutation({
    onSuccess: () => {
      refresh();
      toast.success("Unpublished", { description: "Back to draft: it is off the site, the feed and the Markdown twin." });
    },
    onError: (e) => toast.error(e.message),
  });
  const live = entry.status !== "draft";

  return (
    <TableRow className="cursor-pointer" onClick={onEdit}>
      <TableCell className="max-w-[26rem]">
        <span className="block truncate font-medium">{entry.title}</span>
        <span className="block truncate text-xs text-muted-foreground">{entry.summary}</span>
      </TableCell>
      <TableCell>
        <CategoryBadge category={entry.category} />
      </TableCell>
      <TableCell className="text-muted-foreground">
        {entry.platforms.length ? entry.platforms.map((p) => PLATFORM_LABELS[p]).join(", ") : "—"}
      </TableCell>
      <TableCell className="font-mono text-xs text-muted-foreground">{entry.version ? versionLabel(entry.version) : "—"}</TableCell>
      <TableCell>
        <StatusBadge entry={entry} />
      </TableCell>
      <TableCell onClick={(e) => e.stopPropagation()}>
        <DropdownMenu modal={false}>
          <DropdownMenuTrigger asChild>
            <Button variant="ghost" size="icon" className="h-8 w-8" aria-label={`Actions for ${entry.title}`}>
              <MoreHorizontal className="h-4 w-4" />
            </Button>
          </DropdownMenuTrigger>
          <DropdownMenuContent align="end">
            <DropdownMenuItem onClick={onEdit}>Edit…</DropdownMenuItem>
            {live ? (
              <DropdownMenuItem disabled={unpublish.isPending} onClick={() => unpublish.mutate({ id: entry.id })}>
                Unpublish
              </DropdownMenuItem>
            ) : (
              <DropdownMenuItem disabled={publish.isPending} onClick={() => publish.mutate({ id: entry.id, publishedAt: null })}>
                Publish now
              </DropdownMenuItem>
            )}
            {entry.status === "published" && (
              <DropdownMenuItem asChild>
                <a href={`${PUBLIC_SITE}/changelog/${entry.slug}`} target="_blank" rel="noopener noreferrer">
                  View on capturecat.so
                </a>
              </DropdownMenuItem>
            )}
            <DropdownMenuSeparator />
            <DropdownMenuItem variant="destructive" onClick={() => setConfirmDelete(true)}>
              Delete…
            </DropdownMenuItem>
          </DropdownMenuContent>
        </DropdownMenu>
        <DeleteConfirm open={confirmDelete} onOpenChange={setConfirmDelete} entry={entry} onDeleted={refresh} />
      </TableCell>
    </TableRow>
  );
}

/** Deleting is final: say what disappears before doing it. */
function DeleteConfirm({
  open,
  onOpenChange,
  entry,
  onDeleted,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  entry: AdminChangelogEntry;
  onDeleted: () => void;
}) {
  const del = trpc.admin.deleteChangelogEntry.useMutation({
    onSuccess: () => {
      toast.success("Entry deleted");
      onDeleted();
    },
    onError: (e) => toast.error(e.message),
  });
  return (
    <AlertDialog open={open} onOpenChange={onOpenChange}>
      <AlertDialogContent>
        <AlertDialogHeader>
          <AlertDialogTitle>Delete “{entry.title}”?</AlertDialogTitle>
          <AlertDialogDescription>
            {entry.status === "draft"
              ? "This draft was never published. Deleting it can't be undone."
              : `It comes off capturecat.so/changelog, the RSS feed and the Markdown twin at once, and links to /changelog/${entry.slug} will 404. This can't be undone; to take it down for now, unpublish instead.`}
          </AlertDialogDescription>
        </AlertDialogHeader>
        <AlertDialogFooter>
          <AlertDialogCancel>Cancel</AlertDialogCancel>
          <AlertDialogAction variant="destructive" onClick={() => del.mutate({ id: entry.id })}>
            Delete entry
          </AlertDialogAction>
        </AlertDialogFooter>
      </AlertDialogContent>
    </AlertDialog>
  );
}

const textareaCls =
  "w-full min-w-0 rounded-2xl border border-input bg-input/30 px-3 py-2 text-sm outline-none placeholder:text-muted-foreground focus-visible:border-ring focus-visible:ring-[3px] focus-visible:ring-ring/50";

/**
 * One dialog for writing and editing an entry, after the plan editor: the
 * form on the left, and on the right the entry as the public page renders
 * it — the site's own component, live on every keystroke.
 */
function ChangelogEditorDialog({ entry, onClose }: { entry: AdminChangelogEntry | null; onClose: () => void }) {
  const utils = trpc.useUtils();
  // The entry as last saved: the prop, then whatever each save returned (so a
  // just-created entry keeps editing as itself).
  const [saved, setSaved] = useState<AdminChangelogEntry | null>(entry);
  const [form, setForm] = useState<ChangelogForm>(() => (entry ? formFromEntry(entry) : emptyChangelogForm()));
  const [error, setError] = useState<string | null>(null);
  const [confirmDelete, setConfirmDelete] = useState(false);
  const [confirmDiscard, setConfirmDiscard] = useState(false);
  const create = trpc.admin.createChangelogEntry.useMutation();
  const update = trpc.admin.updateChangelogEntry.useMutation();
  const publish = trpc.admin.publishChangelogEntry.useMutation();
  const unpublish = trpc.admin.unpublishChangelogEntry.useMutation();
  const busy = create.isPending || update.isPending || publish.isPending || unpublish.isPending;
  const set = (patch: Partial<ChangelogForm>) => setForm((f) => ({ ...f, ...patch }));

  const live = !!saved && saved.status !== "draft";
  const dirty = isDirty(form, saved);
  const schedules = isFutureDay(form.date);
  const slugMoved = live && form.slug.trim() !== saved?.slug;

  const requestClose = () => (dirty && !busy ? setConfirmDiscard(true) : onClose());

  /** Create, or save changed content; returns the entry as stored. */
  async function persist(): Promise<AdminChangelogEntry> {
    const input = inputFromForm(form);
    let next = saved;
    if (!next) next = (await create.mutateAsync(input)).entry;
    else if (contentChanged(form, next)) next = (await update.mutateAsync({ id: next.id, ...input })).entry;
    // Remember it at once, so a failed publish never re-creates it on retry.
    setSaved(next);
    return next;
  }

  async function run(action: "draft" | "publish" | "save" | "unpublish") {
    setError(null);
    const problem = action === "unpublish" ? null : formProblem(form);
    if (problem) {
      setError(problem);
      return;
    }
    try {
      let next: AdminChangelogEntry;
      if (action === "unpublish") {
        next = (await unpublish.mutateAsync({ id: saved!.id })).entry;
      } else {
        next = await persist();
        if (action === "publish") {
          next = (await publish.mutateAsync({ id: next.id, publishedAt: publishDate(form) })).entry;
        } else if (action === "save" && next.publishedAt && form.date && form.date !== isoDay(next.publishedAt)) {
          // Re-dating a published entry.
          next = (await publish.mutateAsync({ id: next.id, publishedAt: form.date })).entry;
        }
      }
      setSaved(next);
      setForm(formFromEntry(next));
      await utils.admin.listChangelog.invalidate();
      const where = `${PUBLIC_SITE}/changelog/${next.slug}`;
      if (action === "draft") toast.success("Draft saved");
      else if (action === "unpublish") toast.success("Unpublished", { description: "Back to draft: it is off the site, the feed and the Markdown twin." });
      else if (next.status === "scheduled") toast.success(statusLine(next), { description: where });
      else if (action === "publish") toast.success("Published", { description: where });
      else toast.success("Saved", { description: where });
    } catch (e) {
      setError(e instanceof Error ? e.message : "Something went wrong");
    }
  }

  return (
    <>
      <Dialog open onOpenChange={(o) => !o && requestClose()}>
        <DialogContent className="max-h-[92vh] overflow-y-auto sm:max-w-6xl">
          <DialogHeader>
            <DialogTitle className="flex flex-wrap items-center gap-2 pr-8">
              <span className="truncate">{saved ? saved.title : "New entry"}</span>
              {saved && <StatusBadge entry={saved} />}
            </DialogTitle>
            <DialogDescription>
              {live
                ? "Live on capturecat.so/changelog, its RSS feed and its Markdown twin. Saving updates all three at once."
                : "Drafts are visible only here. Publishing puts the entry on capturecat.so/changelog, its RSS feed (/changelog.xml) and its Markdown twin at once."}
            </DialogDescription>
          </DialogHeader>

          <div className="grid gap-8 lg:grid-cols-2">
            <div className="min-w-0 space-y-5">
              <Section title="Entry">
                <Field label="Title" htmlFor="cl-title">
                  <Input
                    id="cl-title"
                    placeholder="Agents can publish share links"
                    maxLength={CHANGELOG_LIMITS.title}
                    value={form.title}
                    onChange={(e) => setForm((f) => withTitle(f, e.target.value))}
                  />
                </Field>
                <Field
                  label="Slug"
                  htmlFor="cl-slug"
                  hint={
                    slugMoved ? (
                      <span className="text-amber-500">
                        Changing a published slug breaks links to capturecat.so/changelog/{saved?.slug}.
                      </span>
                    ) : (
                      <>
                        capturecat.so/changelog/<span className="text-foreground">{form.slug || "…"}</span>
                        {/* Only before the first save: after that the slug is a URL. */}
                        {!saved && form.slugEdited && form.title.trim() && form.slug !== slugify(form.title) && (
                          <>
                            {" · "}
                            <button
                              type="button"
                              className="underline underline-offset-2 hover:text-foreground"
                              onClick={() => set({ slug: slugify(form.title), slugEdited: false })}
                            >
                              Use the title
                            </button>
                          </>
                        )}
                      </>
                    )
                  }
                >
                  <Input
                    id="cl-slug"
                    placeholder="agents-share-links"
                    value={form.slug}
                    onChange={(e) => set({ slug: cleanSlugInput(e.target.value), slugEdited: true })}
                  />
                </Field>
                <Field
                  label="Summary"
                  htmlFor="cl-summary"
                  hint={`${form.summary.trim().length}/${CHANGELOG_LIMITS.summary} · one line, shown in the list, the RSS feed and search results.`}
                >
                  <Input
                    id="cl-summary"
                    placeholder="What changed, in one sentence."
                    maxLength={CHANGELOG_LIMITS.summary}
                    value={form.summary}
                    onChange={(e) => set({ summary: e.target.value })}
                  />
                </Field>
              </Section>

              <Section title="Labels">
                <Field label="Category">
                  <div className="flex flex-wrap gap-1" role="radiogroup" aria-label="Category">
                    {CATEGORIES.map((c) => (
                      <Button
                        key={c}
                        type="button"
                        size="xs"
                        role="radio"
                        aria-checked={form.category === c}
                        variant={form.category === c ? "default" : "outline"}
                        onClick={() => set({ category: c })}
                      >
                        {CATEGORY_META[c].label}
                      </Button>
                    ))}
                  </div>
                </Field>
                <Field label="Platforms" hint="Any that apply; none is fine for a general update.">
                  <div className="flex flex-wrap gap-1">
                    {CHANGELOG_PLATFORMS.map((p) => (
                      <Button
                        key={p}
                        type="button"
                        size="xs"
                        aria-pressed={form.platforms.includes(p)}
                        variant={form.platforms.includes(p) ? "default" : "outline"}
                        onClick={() => set({ platforms: togglePlatform(form.platforms, p) })}
                      >
                        {PLATFORM_LABELS[p]}
                      </Button>
                    ))}
                  </div>
                </Field>
                <div className="grid gap-3 sm:grid-cols-2">
                  <Field label="Version" htmlFor="cl-version" hint="Blank when it isn't tied to a release.">
                    <Input
                      id="cl-version"
                      placeholder="1.3.1"
                      maxLength={CHANGELOG_LIMITS.version}
                      value={form.version}
                      onChange={(e) => set({ version: e.target.value })}
                    />
                  </Field>
                  <Field
                    label="Date (UTC)"
                    htmlFor="cl-date"
                    hint={
                      live
                        ? "The date it shows. Changing it re-dates the entry."
                        : "Blank: the moment you publish. A past date backdates it; a future one schedules it."
                    }
                  >
                    <Input id="cl-date" type="date" value={form.date} onChange={(e) => set({ date: e.target.value })} />
                  </Field>
                </div>
              </Section>

              <Section
                title="Body"
                description={
                  <>
                    Markdown: <code>##</code> headings, <code>**bold**</code>, <code>*italic*</code>, <code>`code`</code>,
                    lists, <code>&gt;</code> quotes, <code>```</code> code blocks and <code>[links](https://…)</code>. HTML
                    shows as text, and only http(s) links become links.
                  </>
                }
              >
                <textarea
                  id="cl-body"
                  aria-label="Body (Markdown)"
                  rows={16}
                  spellCheck
                  className={`${textareaCls} min-h-[18rem] font-mono text-[13px] leading-relaxed`}
                  placeholder={"## What's new\n\n- One thing\n- Another"}
                  value={form.body}
                  onChange={(e) => set({ body: e.target.value })}
                />
              </Section>
            </div>

            <div className="min-w-0 lg:border-l lg:pl-8">
              <div className="lg:sticky lg:top-0">
                <p className="text-xs font-medium text-muted-foreground">Preview · as capturecat.so/changelog shows it</p>
                <div
                  data-testid="changelog-preview"
                  className="relative mt-3 overflow-hidden rounded-3xl border border-white/10 bg-white/[0.035] p-6 backdrop-blur-2xl"
                >
                  <span
                    aria-hidden
                    className="absolute inset-x-8 top-0 h-px bg-gradient-to-r from-transparent via-white/30 to-transparent"
                  />
                  <ChangelogEntryView entry={previewEntry(form, saved)} />
                </div>
              </div>
            </div>
          </div>

          {error && <p className="text-sm text-destructive">{error}</p>}

          <DialogFooter className="sm:justify-between">
            <div>
              {saved && (
                <Button variant="destructive" disabled={busy} onClick={() => setConfirmDelete(true)}>
                  <Trash2 className="mr-1 h-4 w-4" /> Delete…
                </Button>
              )}
            </div>
            <div className="flex flex-col-reverse gap-2 sm:flex-row">
              <Button variant="outline" onClick={requestClose}>
                {dirty ? "Cancel" : "Close"}
              </Button>
              {live ? (
                <>
                  <Button variant="outline" disabled={busy} onClick={() => run("unpublish")}>
                    Unpublish
                  </Button>
                  <Button disabled={busy || !dirty} onClick={() => run("save")}>
                    {busy ? "Saving…" : "Save"}
                  </Button>
                </>
              ) : (
                <>
                  <Button variant="outline" disabled={busy || (!!saved && !dirty)} onClick={() => run("draft")}>
                    Save draft
                  </Button>
                  <Button disabled={busy} onClick={() => run("publish")}>
                    {busy ? "Saving…" : schedules ? "Schedule" : "Publish"}
                  </Button>
                </>
              )}
            </div>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      {saved && (
        <DeleteConfirm
          open={confirmDelete}
          onOpenChange={setConfirmDelete}
          entry={saved}
          onDeleted={() => {
            utils.admin.listChangelog.invalidate();
            onClose();
          }}
        />
      )}

      <AlertDialog open={confirmDiscard} onOpenChange={setConfirmDiscard}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>Discard your changes?</AlertDialogTitle>
            <AlertDialogDescription>
              {saved ? "The entry keeps what was last saved." : "This entry hasn't been saved, so it will be gone."}
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>Keep editing</AlertDialogCancel>
            <AlertDialogAction variant="destructive" onClick={onClose}>
              Discard
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </>
  );
}
