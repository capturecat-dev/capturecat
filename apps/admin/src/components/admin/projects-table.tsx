import { useEffect, useState } from "react";
import { FolderOpen, Search } from "lucide-react";

import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Empty, EmptyDescription, EmptyHeader, EmptyMedia, EmptyTitle } from "@/components/ui/empty";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { TableLoading } from "@/components/ui/table-loading";
import { ProjectSheet } from "@/components/admin/project-sheet";
import { formatBytes, plural, relativeTime } from "@/lib/format";
import type { AdminProjectPage, ProjectFilter } from "@/lib/project-types";
import { trpc } from "@/lib/trpc/client";

const FILTERS: Array<{ id: ProjectFilter; label: string }> = [
  { id: "all", label: "All projects" },
  { id: "unshared", label: "Never shared" },
  { id: "shared", label: "Shared" },
];

const EMPTY: Record<ProjectFilter, { title: string; body: string }> = {
  all: { title: "No projects yet", body: "Web recordings and Mac projects opened in the web editor appear here." },
  unshared: { title: "Everything was shared", body: "Every cloud project has at least one shared video." },
  shared: { title: "Nothing shared yet", body: "Projects show here once a video is shared from them." },
};

/** The search box both toolbars use (this page and the Videos page). */
export function SearchBox({
  value,
  placeholder,
  label,
  onChange,
  onSubmit,
}: {
  value: string;
  placeholder: string;
  label: string;
  onChange: (value: string) => void;
  onSubmit: () => void;
}) {
  return (
    <form
      className="relative w-full sm:w-72"
      onSubmit={(e) => {
        e.preventDefault();
        onSubmit();
      }}
    >
      <Search className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" />
      <Input value={value} onChange={(e) => onChange(e.target.value)} placeholder={placeholder} className="pl-9" aria-label={label} />
    </form>
  );
}

/**
 * The Projects page: every cloud project, newest first, or only the ones
 * never shared as a video (or only the shared ones). Search by name, owner
 * email or project id. A row opens the project sheet.
 */
export function ProjectsTable() {
  const [filter, setFilter] = useState<ProjectFilter>("all");
  const [search, setSearch] = useState("");
  const [query, setQuery] = useState("");
  const [counts, setCounts] = useState<AdminProjectPage["counts"] | null>(null);

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div role="tablist" aria-label="Which projects" className="flex flex-wrap gap-1.5">
          {FILTERS.map((f) => (
            <Button
              key={f.id}
              role="tab"
              aria-selected={filter === f.id}
              size="sm"
              variant={filter === f.id ? "secondary" : "ghost"}
              onClick={() => setFilter(f.id)}
            >
              {f.label}
              {counts && (
                <Badge variant="outline" className="ml-1.5">
                  {counts[f.id]}
                </Badge>
              )}
            </Button>
          ))}
        </div>
        <SearchBox
          value={search}
          placeholder="Name, owner email or project id"
          label="Search projects"
          onChange={(v) => {
            setSearch(v);
            if (!v) setQuery("");
          }}
          onSubmit={() => setQuery(search.trim())}
        />
      </div>
      <ProjectsList filter={filter} query={query} onCounts={setCounts} />
    </div>
  );
}

/**
 * The list itself — the Projects page's table, and the Videos page's "Never
 * shared" tab (recordings that are on CaptureCat but were never shared).
 */
export function ProjectsList({
  filter,
  query,
  onCounts,
}: {
  filter: ProjectFilter;
  query: string;
  onCounts?: (counts: AdminProjectPage["counts"]) => void;
}) {
  const [open, setOpen] = useState<string | null>(null);
  const list = trpc.admin.listProjects.useInfiniteQuery(
    { filter, q: query || undefined },
    { getNextPageParam: (last) => last.nextCursor ?? undefined },
  );
  const pages = list.data?.pages ?? [];
  const projects = pages.flatMap((p) => p.projects);
  const counts = pages[0]?.counts;
  useEffect(() => {
    if (counts) onCounts?.(counts);
  }, [counts, onCounts]);

  return (
    <div className="space-y-4">
      {list.error && <p className="text-sm text-destructive">{list.error.message}</p>}

      {list.isLoading ? (
        <TableLoading />
      ) : projects.length === 0 && !list.error ? (
        <Empty className="border">
          <EmptyHeader>
            <EmptyMedia variant="icon">
              <FolderOpen />
            </EmptyMedia>
            <EmptyTitle>{query ? "No matches" : EMPTY[filter].title}</EmptyTitle>
            <EmptyDescription>{query ? `Nothing matches “${query}”.` : EMPTY[filter].body}</EmptyDescription>
          </EmptyHeader>
        </Empty>
      ) : (
        <div className="overflow-x-auto rounded-2xl border">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead className="w-[45%]">Project</TableHead>
                <TableHead>Created</TableHead>
                <TableHead>Last edited</TableHead>
                <TableHead>Shared</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {projects.map((p) => (
                <TableRow key={p.projectId} className="cursor-pointer" onClick={() => setOpen(p.projectId)}>
                  <TableCell>
                    <div className="flex min-w-0 items-center gap-3">
                      <div className="grid h-10 w-16 shrink-0 place-items-center rounded-md bg-muted text-muted-foreground">
                        <FolderOpen className="h-4 w-4" />
                      </div>
                      <div className="min-w-0">
                        <p className="truncate font-medium">{p.name}</p>
                        <p className="truncate text-xs text-muted-foreground">
                          {p.owner.email ?? "unknown owner"}
                          {p.team ? ` · ${p.team.name ?? "team"}` : ""} · {formatBytes(p.totalBytes)} · {plural(p.fileCount, "file")}
                        </p>
                      </div>
                    </div>
                  </TableCell>
                  <TableCell className="whitespace-nowrap text-muted-foreground">{relativeTime(p.createdAt)}</TableCell>
                  <TableCell className="whitespace-nowrap text-muted-foreground">{relativeTime(p.updatedAt)}</TableCell>
                  <TableCell>
                    {!p.uploaded ? (
                      <Badge variant="outline">Uploading</Badge>
                    ) : p.shares > 0 ? (
                      <Badge variant="secondary" title={p.lastShareAt ? `Last ${relativeTime(p.lastShareAt)}` : undefined}>
                        {plural(p.shares, "video")}
                      </Badge>
                    ) : (
                      <Badge variant="outline">Never shared</Badge>
                    )}
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </div>
      )}

      {list.hasNextPage && (
        <div className="flex justify-center">
          <Button size="sm" variant="outline" disabled={list.isFetchingNextPage} onClick={() => list.fetchNextPage()}>
            {list.isFetchingNextPage ? "Loading…" : "Load more"}
          </Button>
        </div>
      )}

      <ProjectSheet projectId={open} onClose={() => setOpen(null)} />
    </div>
  );
}
