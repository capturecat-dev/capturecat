import { useState, type ReactNode } from "react";

import { Badge } from "@/components/ui/badge";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { TableLoading } from "@/components/ui/table-loading";
import { DailyBars } from "@/components/admin/analytics/daily-bars";
import { Meter } from "@/components/admin/analytics/meter";
import { UserActivitySheet } from "@/components/admin/user-activity-sheet";
import { trpc } from "@/lib/trpc/client";
import type { Analytics } from "@/lib/analytics-types";
import {
  PROVIDER_LABEL,
  SOURCE_KIND_LABEL,
  countryLabel,
  formatBytes,
  formatDuration,
  formatNumber,
  formatPercent,
  plural,
  relativeTime,
} from "@/lib/format";
import { cn } from "@/lib/utils";

export type Days = 7 | 30 | 90 | 365;
const RANGES: Array<{ days: Days; label: string }> = [
  { days: 7, label: "7 days" },
  { days: 30, label: "30 days" },
  { days: 90, label: "90 days" },
  { days: 365, label: "12 months" },
];

export function RangePicker({ days, onChange }: { days: Days; onChange: (d: Days) => void }) {
  return (
    <div className="inline-flex rounded-lg border p-0.5" role="radiogroup" aria-label="Date range">
      {RANGES.map((r) => (
        <button
          key={r.days}
          type="button"
          role="radio"
          aria-checked={days === r.days}
          onClick={() => onChange(r.days)}
          className={cn(
            "whitespace-nowrap rounded-md px-3 py-1 text-sm transition-colors",
            days === r.days ? "bg-secondary text-secondary-foreground" : "text-muted-foreground hover:text-foreground",
          )}
        >
          {r.label}
        </button>
      ))}
    </div>
  );
}

/**
 * One stacked surface, hairline sections (the house rule for console pages),
 * with the range control as the only filter, in one row above everything it
 * scopes. All-time figures are labelled as such.
 */
export function AnalyticsBody({ days }: { days: Days }) {
  const { data, isLoading, error } = trpc.admin.analytics.useQuery({ days });
  const [userId, setUserId] = useState<string | null>(null);

  if (isLoading) return <TableLoading />;
  if (error || !data) return <p className="text-sm text-destructive">{error?.message ?? "Could not load analytics."}</p>;

  return (
    <div className="flex flex-col divide-y">
      <Kpis a={data} />
      <Section
        title="Trend"
        note={`Per ${data.daily.length > 90 ? "week" : "day"}, UTC. Visits and downloads are anonymous site events; uploads are finished shares.`}
      >
        <div className="grid gap-8 sm:grid-cols-2 xl:grid-cols-4">
          <DailyBars title="Site visits" points={data.daily.map((d) => ({ day: d.day, value: d.visits }))} />
          <DailyBars title="Mac downloads" points={data.daily.map((d) => ({ day: d.day, value: d.downloads }))} />
          <DailyBars title="Sign-ups" points={data.daily.map((d) => ({ day: d.day, value: d.signups }))} />
          <DailyBars title="Videos shared" points={data.daily.map((d) => ({ day: d.day, value: d.uploads }))} />
        </div>
      </Section>
      <Sources a={data} />
      <Countries a={data} />
      <Section title="Landing pages and devices" note="Where visits start, and what they arrive on.">
        <div className="grid gap-8 lg:grid-cols-[2fr_1fr]">
          <LandingTable a={data} />
          <DeviceTable a={data} />
        </div>
      </Section>
      <SignupPath a={data} />
      <Features a={data} />
      <Storage a={data} onUser={setUserId} />
      <UserActivitySheet userId={userId} onClose={() => setUserId(null)} />
    </div>
  );
}

function Section({ title, note, children }: { title: string; note?: string; children: ReactNode }) {
  return (
    <section className="py-6 first:pt-0">
      <div className="mb-4 space-y-1">
        <h2 className="text-base font-medium">{title}</h2>
        {note && <p className="text-xs text-muted-foreground">{note}</p>}
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

function Kpis({ a }: { a: Analytics }) {
  const t = a.totals;
  const rangeLabel = RANGES.find((r) => r.days === a.range.days)?.label ?? `${a.range.days} days`;
  return (
    <section className="pb-6">
      <div className="grid grid-cols-2 gap-x-8 gap-y-6 sm:grid-cols-3 xl:grid-cols-6">
        <Stat label="Users" value={formatNumber(t.users)} sub={`+${formatNumber(t.signups)} in ${rangeLabel}`} />
        <Stat label="Active · 7 days" value={formatNumber(t.active7d)} sub={`${formatNumber(t.active1d)} today · ${formatNumber(t.active30d)} in 30d`} />
        <Stat label="Paying" value={formatNumber(t.paid)} sub={`${plural(t.testers, "tester")} · ${formatPercent(t.paid, t.users)} of users`} />
        <Stat label={`Site visits · ${rangeLabel}`} value={formatNumber(t.visits)} sub={`${plural(t.downloads, "download")} (${formatPercent(t.downloads, t.visits)})`} />
        <Stat label={`Shared · ${rangeLabel}`} value={formatNumber(t.uploads)} sub={plural(t.views, "viewer session")} />
        <Stat label="Stored" value={formatBytes(a.storage.totalBytes)} sub={`by ${plural(a.storage.usersStoring, "user")}`} />
      </div>
    </section>
  );
}

function Sources({ a }: { a: Analytics }) {
  const max = Math.max(1, ...a.sources.map((s) => s.visits));
  return (
    <Section
      title="Where they come from"
      note="Visits and downloads come from anonymous, cookieless site events. Sign-ups are attributed when the account is made in the browser; a sign-up through the Mac app has no page behind it, so its source shows up in visits and downloads instead. AI assistants are often invisible: their apps send no referrer, and only ChatGPT tags its links."
    >
      {a.sources.length === 0 ? (
        <Empty>No traffic recorded in this range yet.</Empty>
      ) : (
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>Source</TableHead>
              <TableHead>Type</TableHead>
              <TableHead className="text-right">Visits</TableHead>
              <TableHead className="text-right">Downloads</TableHead>
              <TableHead className="text-right">Visit → download</TableHead>
              <TableHead className="text-right">Sign-ups</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {a.sources.map((s) => (
              <TableRow key={s.id}>
                <TableCell>
                  <div className="flex flex-col">
                    <span className="font-medium">{s.label}</span>
                    {s.hosts.length > 0 && s.hosts[0]!.host !== s.label && (
                      <span className="text-xs text-muted-foreground">
                        {s.hosts.map((h) => `${h.host} (${formatNumber(h.visits)})`).join(", ")}
                      </span>
                    )}
                  </div>
                </TableCell>
                <TableCell>
                  <Badge variant={s.kind === "ai" ? "default" : "outline"}>{SOURCE_KIND_LABEL[s.kind] ?? s.kind}</Badge>
                </TableCell>
                <TableCell className="text-right">
                  <Meter value={s.visits} max={max}>{formatNumber(s.visits)}</Meter>
                </TableCell>
                <TableCell className="text-right tabular-nums">{formatNumber(s.downloads)}</TableCell>
                <TableCell className="text-right tabular-nums text-muted-foreground">{formatPercent(s.downloads, s.visits)}</TableCell>
                <TableCell className="text-right tabular-nums">{formatNumber(s.signups)}</TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      )}
    </Section>
  );
}

function Countries({ a }: { a: Analytics }) {
  const max = Math.max(1, ...a.countries.map((c) => c.visits));
  return (
    <Section title="Countries" note="From Cloudflare's geolocation of each request. A sign-up's country is where it completed sign-in.">
      {a.countries.length === 0 ? (
        <Empty>Nothing recorded in this range yet.</Empty>
      ) : (
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>Country</TableHead>
              <TableHead className="text-right">Visits</TableHead>
              <TableHead className="text-right">Downloads</TableHead>
              <TableHead className="text-right">Sign-ups</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {a.countries.map((c) => (
              <TableRow key={c.country}>
                <TableCell>{countryLabel(c.country)}</TableCell>
                <TableCell className="text-right">
                  <Meter value={c.visits} max={max}>{formatNumber(c.visits)}</Meter>
                </TableCell>
                <TableCell className="text-right tabular-nums">{formatNumber(c.downloads)}</TableCell>
                <TableCell className="text-right tabular-nums">{formatNumber(c.signups)}</TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      )}
    </Section>
  );
}

function LandingTable({ a }: { a: Analytics }) {
  const max = Math.max(1, ...a.landings.map((l) => l.visits));
  if (a.landings.length === 0) return <Empty>No landings yet.</Empty>;
  return (
    <Table>
      <TableHeader>
        <TableRow>
          <TableHead>Landing page</TableHead>
          <TableHead className="text-right">Visits</TableHead>
          <TableHead className="text-right">Downloads</TableHead>
        </TableRow>
      </TableHeader>
      <TableBody>
        {a.landings.map((l) => (
          <TableRow key={l.path}>
            <TableCell className="max-w-[20rem] truncate font-mono text-xs">{l.path}</TableCell>
            <TableCell className="text-right">
              <Meter value={l.visits} max={max}>{formatNumber(l.visits)}</Meter>
            </TableCell>
            <TableCell className="text-right tabular-nums">{formatNumber(l.downloads)}</TableCell>
          </TableRow>
        ))}
      </TableBody>
    </Table>
  );
}

const DEVICE_LABEL: Record<string, string> = {
  mac: "Mac",
  windows: "Windows",
  ios: "iPhone / iPad",
  android: "Android",
  linux: "Linux / ChromeOS",
  other: "Other",
};

function DeviceTable({ a }: { a: Analytics }) {
  if (a.devices.length === 0) return <Empty>No devices yet.</Empty>;
  const total = a.devices.reduce((n, d) => n + d.visits, 0);
  return (
    <Table>
      <TableHeader>
        <TableRow>
          <TableHead>Device</TableHead>
          <TableHead className="text-right">Visits</TableHead>
          <TableHead className="text-right">Share</TableHead>
        </TableRow>
      </TableHeader>
      <TableBody>
        {a.devices.map((d) => (
          <TableRow key={d.device}>
            <TableCell>{DEVICE_LABEL[d.device] ?? d.device}</TableCell>
            <TableCell className="text-right tabular-nums">{formatNumber(d.visits)}</TableCell>
            <TableCell className="text-right tabular-nums text-muted-foreground">{formatPercent(d.visits, total)}</TableCell>
          </TableRow>
        ))}
      </TableBody>
    </Table>
  );
}

function SignupPath({ a }: { a: Analytics }) {
  const v = a.signupVia;
  const total = v.web + v.desktop + v.unknown;
  return (
    <Section title="How they sign up" note="Sign-ups in this range by where the account was made, and sign-in providers across all users.">
      <div className="grid gap-8 sm:grid-cols-2">
        <Facts
          rows={[
            ["Mac app", `${formatNumber(v.desktop)} (${formatPercent(v.desktop, total)})`],
            ["Browser", `${formatNumber(v.web)} (${formatPercent(v.web, total)})`],
            ...(v.unknown ? [["Before tracking", formatNumber(v.unknown)] as [string, string]] : []),
          ]}
        />
        <Facts
          rows={a.providers.map((p) => [PROVIDER_LABEL[p.provider] ?? p.provider, plural(p.users, "user")])}
        />
      </div>
    </Section>
  );
}

function Features({ a }: { a: Analytics }) {
  const users = Math.max(1, a.totals.users);
  const rangeLabel = RANGES.find((r) => r.days === a.range.days)?.label ?? `${a.range.days} days`;
  const clientLabel = (c: string) => (c === "mac" ? "Mac app" : c === "web" ? "Web editor" : "Unknown client");
  return (
    <Section
      title="What they do"
      note="Users who have used each server-side feature. Recording and exporting happen on the Mac and are not visible here."
    >
      <div className="grid gap-8 lg:grid-cols-[3fr_2fr]">
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>Feature</TableHead>
              <TableHead className="text-right">Users, all time</TableHead>
              <TableHead className="text-right">In {rangeLabel}</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {a.features.map((f) => (
              <TableRow key={f.id}>
                <TableCell>{f.label}</TableCell>
                <TableCell className="text-right">
                  <Meter value={f.users} max={users}>{formatNumber(f.users)}</Meter>
                </TableCell>
                <TableCell className="text-right tabular-nums text-muted-foreground">
                  {f.usersInRange === null ? "—" : formatNumber(f.usersInRange)}
                </TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
        <div className="space-y-6">
          <div>
            <h3 className="mb-2 text-sm font-medium">Cloud editing sessions · {rangeLabel}</h3>
            {a.edits.length === 0 ? (
              <Empty>No cloud project edits in this range.</Empty>
            ) : (
              <Facts
                rows={a.edits.map((e) => [
                  `${clientLabel(e.client)}${e.source === "human" ? "" : ` · ${e.source === "agent" ? "AI agent" : "human + agent"}`}`,
                  `${plural(e.sessions, "session")} on ${plural(e.projects, "project")}`,
                ])}
              />
            )}
          </div>
          <Facts
            rows={[
              ["Shared videos, all time", `${formatNumber(a.totals.videos)} · ${formatDuration(a.totals.videoSeconds)}`],
              ["Cloud projects", formatNumber(a.totals.projects)],
              ["Stored screenshots", formatNumber(a.totals.screenshots)],
              ["Teams", formatNumber(a.totals.orgs)],
            ]}
          />
        </div>
      </div>
    </Section>
  );
}

function Storage({ a, onUser }: { a: Analytics; onUser: (id: string) => void }) {
  const s = a.storage;
  const kinds: Array<[string, number]> = [
    ["Shared videos (incl. versions)", s.videoBytes],
    ["Cloud projects (incl. history)", s.projectBytes],
    ["Screenshots", s.screenshotBytes],
  ];
  const maxKind = Math.max(1, ...kinds.map(([, b]) => b));
  return (
    <Section
      title="What they store"
      note="Bytes on CaptureCat's storage. Videos in a user's own bucket are not counted, matching the quota."
    >
      <div className="mb-6 max-w-xl space-y-2">
        {kinds.map(([label, bytes]) => (
          <div key={label} className="flex items-center justify-between gap-4">
            <span className="text-sm">{label}</span>
            <div className="w-64">
              <Meter value={bytes} max={maxKind}>{formatBytes(bytes)}</Meter>
            </div>
          </div>
        ))}
      </div>
      {a.topUsers.length === 0 ? (
        <Empty>Nobody stores anything yet.</Empty>
      ) : (
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>Top users by storage</TableHead>
              <TableHead className="text-right">Stored</TableHead>
              <TableHead className="text-right">Videos</TableHead>
              <TableHead className="text-right">Projects</TableHead>
              <TableHead className="text-right">Screenshots</TableHead>
              <TableHead className="text-right">Last active</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {a.topUsers.map((u) => (
              <TableRow key={u.id} className="cursor-pointer" onClick={() => onUser(u.id)}>
                <TableCell>
                  <div className="flex flex-col">
                    <span className="font-medium">{u.email}</span>
                    {u.name && <span className="text-xs text-muted-foreground">{u.name}</span>}
                  </div>
                </TableCell>
                <TableCell className="text-right">
                  <Meter value={u.storageBytes} max={a.topUsers[0]!.storageBytes}>{formatBytes(u.storageBytes)}</Meter>
                </TableCell>
                <TableCell className="text-right tabular-nums">{formatNumber(u.videos)}</TableCell>
                <TableCell className="text-right tabular-nums">{formatNumber(u.projects)}</TableCell>
                <TableCell className="text-right tabular-nums">{formatNumber(u.screenshots)}</TableCell>
                <TableCell className="text-right text-xs text-muted-foreground">{relativeTime(u.lastActive)}</TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      )}
    </Section>
  );
}

function Facts({ rows }: { rows: Array<[string, string]> }) {
  if (rows.length === 0) return <Empty>Nothing yet.</Empty>;
  return (
    <dl className="grid grid-cols-[auto_1fr] gap-x-6 gap-y-1.5 text-sm">
      {rows.map(([k, v]) => (
        <div key={k} className="contents">
          <dt className="text-muted-foreground">{k}</dt>
          <dd className="tabular-nums">{v}</dd>
        </div>
      ))}
    </dl>
  );
}

function Empty({ children }: { children: ReactNode }) {
  return <p className="text-sm text-muted-foreground">{children}</p>;
}
