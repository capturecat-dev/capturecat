import type { ReactNode } from "react";

import { Badge } from "@/components/ui/badge";
import { Sheet, SheetContent, SheetDescription, SheetHeader, SheetTitle } from "@/components/ui/sheet";
import { Spinner } from "@/components/ui/spinner";
import { trpc } from "@/lib/trpc/client";
import { UserPlanSection } from "@/components/admin/user-plan-section";
import type { SignupSource } from "@/lib/analytics-types";
import {
  PROVIDER_LABEL,
  SOURCE_KIND_LABEL,
  countryLabel,
  formatBytes,
  formatDuration,
  formatNumber,
  relativeTime,
} from "@/lib/format";

/**
 * One user's footprint: where they came from, what they store, what they
 * shared and how it was watched, their cloud projects and their devices.
 * Opened from the Users table and from Analytics' top-storage list.
 */
export function UserActivitySheet({ userId, onClose }: { userId: string | null; onClose: () => void }) {
  const { data, isLoading, error } = trpc.admin.userActivity.useQuery(
    { userId: userId ?? "" },
    { enabled: userId !== null },
  );

  return (
    <Sheet open={userId !== null} onOpenChange={(open) => !open && onClose()}>
      <SheetContent className="w-full overflow-y-auto data-[side=right]:sm:max-w-2xl">
        <SheetHeader>
          <SheetTitle>{data?.user.email ?? "User"}</SheetTitle>
          <SheetDescription>
            {data ? `${data.user.name ?? "No name"} · joined ${relativeTime(data.user.createdAt)}` : " "}
          </SheetDescription>
        </SheetHeader>

        {isLoading && (
          <div className="flex justify-center p-8">
            <Spinner />
          </div>
        )}
        {error && <p className="px-4 text-sm text-destructive">{error.message}</p>}

        {data && (
          <div className="flex flex-col divide-y px-4 pb-8">
            <Section title="Plan">
              <UserPlanSection userId={data.user.id} email={data.user.email} />
            </Section>

            <Section title="Came from">
              <SignupFacts signup={data.signup} providers={data.providers} />
            </Section>

            <Section title="Stores">
              <Facts
                rows={[
                  ["Total on CaptureCat", formatBytes(data.usage.storageBytes)],
                  ["Shared videos", `${formatBytes(data.usage.videoBytes)} · ${formatNumber(data.usage.videos)} videos · ${formatDuration(data.usage.videoSeconds)}`],
                  ["Cloud projects", `${formatBytes(data.usage.projectBytes)} · ${formatNumber(data.usage.projects)} projects (incl. history)`],
                  ["Screenshots", `${formatBytes(data.screenshots.bytes)} · ${formatNumber(data.screenshots.stored)} stored`],
                ]}
              />
              {data.screenshots.apiByMonth.length > 0 && (
                <p className="mt-2 text-xs text-muted-foreground">
                  Screenshot API:{" "}
                  {data.screenshots.apiByMonth
                    .map((m) => `${/^\d{6}$/.test(m.month) ? `${m.month.slice(0, 4)}-${m.month.slice(4)}` : m.month}: ${formatNumber(m.count)}`)
                    .join(" · ")}
                </p>
              )}
            </Section>

            <Section title="Activity">
              <Facts
                rows={[
                  ["Last active", relativeTime(data.usage.lastActive)],
                  ["Views on their shares", formatNumber(data.usage.views)],
                  ...data.edits.map(
                    (e): [string, string] => [
                      `Editing sessions · ${e.client === "mac" ? "Mac app" : e.client === "web" ? "web editor" : "unknown client"}${e.source === "agent" ? " · AI agent" : e.source === "mixed" ? " · human + agent" : ""}`,
                      `${formatNumber(e.sessions)} · last ${relativeTime(e.last)}`,
                    ],
                  ),
                ]}
              />
              {data.sessions.length > 0 && (
                <ul className="mt-3 space-y-1 text-xs text-muted-foreground">
                  {data.sessions.map((s, i) => (
                    <li key={i} className="flex justify-between gap-4" title={s.userAgent ?? undefined}>
                      <span>{s.client}</span>
                      <span>seen {relativeTime(s.lastSeen)} · signed in {relativeTime(s.created)}</span>
                    </li>
                  ))}
                </ul>
              )}
            </Section>

            <Section title={`Shared videos (${data.videos.length})`}>
              {data.videos.length === 0 ? (
                <Empty>No shared videos.</Empty>
              ) : (
                <ul className="space-y-2">
                  {data.videos.map((v) => (
                    <li key={v.id} className="flex items-start justify-between gap-4">
                      <div className="min-w-0">
                        <p className="truncate">{v.title}</p>
                        <p className="text-xs text-muted-foreground">
                          {relativeTime(v.createdAt)} · {formatDuration(v.seconds)} · {formatNumber(v.views)} views
                          {v.comments > 0 && ` · ${formatNumber(v.comments)} comments`}
                          {v.versions > 1 && ` · v${v.versions}`}
                        </p>
                      </div>
                      <div className="flex shrink-0 items-center gap-1.5">
                        {v.private && <Badge variant="outline">Private</Badge>}
                        {v.ownBucket && <Badge variant="outline">Own bucket</Badge>}
                        <span className="w-16 text-right text-xs tabular-nums text-muted-foreground">{formatBytes(v.bytes)}</span>
                      </div>
                    </li>
                  ))}
                </ul>
              )}
            </Section>

            <Section title={`Cloud projects (${data.projects.length})`}>
              {data.projects.length === 0 ? (
                <Empty>No cloud projects.</Empty>
              ) : (
                <ul className="space-y-2">
                  {data.projects.map((p) => (
                    <li key={p.id} className="flex items-start justify-between gap-4">
                      <div className="min-w-0">
                        <p className="truncate">{p.name}</p>
                        <p className="text-xs text-muted-foreground">
                          edited {relativeTime(p.updatedAt)} · {formatNumber(p.versions)} versions
                          {p.historyBytes > 0 && ` · ${formatBytes(p.historyBytes)} history`}
                        </p>
                      </div>
                      <div className="flex shrink-0 items-center gap-1.5">
                        {p.team && <Badge variant="outline">Team</Badge>}
                        <span className="w-16 text-right text-xs tabular-nums text-muted-foreground">{formatBytes(p.bytes)}</span>
                      </div>
                    </li>
                  ))}
                </ul>
              )}
            </Section>
          </div>
        )}
      </SheetContent>
    </Sheet>
  );
}

export function SignupFacts({ signup, providers }: { signup: SignupSource; providers: string[] }) {
  if (!signup.via) {
    return (
      <Facts
        rows={[
          ["Source", "Signed up before tracking started"],
          ["Signs in with", providers.map((p) => PROVIDER_LABEL[p] ?? p).join(", ") || "—"],
        ]}
      />
    );
  }
  const src = signup.source;
  return (
    <Facts
      rows={[
        [
          "Source",
          signup.via === "desktop" && src?.id === "direct"
            ? "Mac app sign-in (source not visible)"
            : src
              ? `${src.label} · ${SOURCE_KIND_LABEL[src.kind] ?? src.kind}`
              : "—",
        ],
        ["Country", countryLabel(signup.country)],
        ["Signed up in", signup.via === "desktop" ? "Mac app" : "Browser"],
        ["Signs in with", providers.map((p) => PROVIDER_LABEL[p] ?? p).join(", ") || "—"],
        ...(signup.referrer ? [["Referrer", signup.referrer] as [string, string]] : []),
        ...(signup.utm ? [["Campaign", signup.utm.split("|").filter(Boolean).join(" / ")] as [string, string]] : []),
        ...(signup.landing ? [["Landed on", signup.landing] as [string, string]] : []),
      ]}
    />
  );
}

function Section({ title, children }: { title: string; children: ReactNode }) {
  return (
    <section className="py-4">
      <h3 className="mb-3 text-xs font-medium uppercase tracking-wide text-muted-foreground">{title}</h3>
      {children}
    </section>
  );
}

function Facts({ rows }: { rows: Array<[string, string]> }) {
  return (
    <dl className="grid grid-cols-[auto_1fr] gap-x-6 gap-y-1.5">
      {rows.map(([k, v]) => (
        <div key={k} className="contents">
          <dt className="text-muted-foreground">{k}</dt>
          <dd className="min-w-0 break-words">{v}</dd>
        </div>
      ))}
    </dl>
  );
}

function Empty({ children }: { children: ReactNode }) {
  return <p className="text-muted-foreground">{children}</p>;
}
