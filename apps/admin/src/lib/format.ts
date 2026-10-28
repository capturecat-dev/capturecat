/** Display formatting shared by the analytics page and the users table. */

export function formatBytes(bytes: number): string {
  if (!bytes) return "0 B";
  const units = ["B", "KB", "MB", "GB", "TB"];
  const i = Math.min(units.length - 1, Math.floor(Math.log(bytes) / Math.log(1024)));
  const v = bytes / 1024 ** i;
  return `${v >= 100 || i === 0 ? Math.round(v) : v.toFixed(1)} ${units[i]}`;
}

export function formatDuration(seconds: number): string {
  const s = Math.round(seconds);
  if (s < 60) return `${s}s`;
  const m = Math.floor(s / 60);
  if (m < 60) return `${m}m ${s % 60}s`;
  return `${Math.floor(m / 60)}h ${m % 60}m`;
}

export const formatNumber = (n: number) => n.toLocaleString("en-US");

/** "1 user", "2 users". */
export const plural = (n: number, one: string, many = `${one}s`) => `${formatNumber(n)} ${n === 1 ? one : many}`;

export function formatPercent(part: number, whole: number): string {
  if (!whole) return "—";
  const p = (part / whole) * 100;
  return `${p < 10 && p > 0 ? p.toFixed(1) : Math.round(p)}%`;
}

export function relativeTime(iso: string | null | undefined, now = Date.now()): string {
  if (!iso) return "never";
  const t = Date.parse(iso);
  if (Number.isNaN(t)) return iso;
  const s = Math.max(0, Math.round((now - t) / 1000));
  if (s < 60) return "just now";
  if (s < 3600) return `${Math.floor(s / 60)}m ago`;
  if (s < 86_400) return `${Math.floor(s / 3600)}h ago`;
  if (s < 30 * 86_400) return `${Math.floor(s / 86_400)}d ago`;
  return new Date(t).toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric" });
}

const regionNames =
  typeof Intl !== "undefined" && "DisplayNames" in Intl
    ? new Intl.DisplayNames(["en"], { type: "region" })
    : null;

/** "DE" → "🇩🇪 Germany"; missing → "Unknown". */
export function countryLabel(code: string | null | undefined): string {
  if (!code || !/^[A-Z]{2}$/.test(code)) return "Unknown";
  const flag = String.fromCodePoint(...[...code].map((c) => 0x1f1a5 + c.charCodeAt(0)));
  let name = code;
  try {
    name = regionNames?.of(code) ?? code;
  } catch {
    // Unassigned code: show it raw.
  }
  return `${flag} ${name}`;
}

export const PROVIDER_LABEL: Record<string, string> = {
  google: "Google",
  apple: "Apple",
  sso: "SSO",
};

export const SOURCE_KIND_LABEL: Record<string, string> = {
  ai: "AI assistant",
  search: "Search",
  social: "Social",
  campaign: "Campaign",
  referral: "Referral",
  direct: "Direct",
};
