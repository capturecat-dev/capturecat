/**
 * The plan editor's model — what it shows, and how a form becomes the body
 * of POST/PUT /api/admin/plans. Kept free of React so the API's test suite
 * imports it (apps/api/src/routes/admin-plans.test.ts) and proves that every
 * gate the API enforces has a field here and survives a save. Two limit keys
 * were once missing from the editor, which made them impossible to change
 * without SQL.
 *
 * The key lists mirror FEATURE_KEYS / LIMIT_KEYS in apps/api/src/lib/plans.ts.
 * Anything else in a plan's JSON is inert, so the editor shows exactly these
 * rather than whatever a row happens to contain — a stale key would otherwise
 * look like a working toggle.
 */

export const FEATURE_FIELDS: ReadonlyArray<{ key: string; label: string; hint: string }> = [
  { key: "cloudShare", label: "Cloud sharing", hint: "Upload and get a share link" },
  { key: "imageUpload", label: "Screenshots", hint: "Upload stills, not just recordings" },
  { key: "webCapture", label: "URL capture", hint: "Capture a web page by address" },
  { key: "comments", label: "Comments", hint: "Viewers can comment on a shared video" },
  { key: "removeWatermark", label: "No watermark", hint: "Export without the CaptureCat mark" },
  { key: "customDomain", label: "Custom domain", hint: "Share pages on the customer's own CNAME" },
  { key: "aiSummaries", label: "AI summaries", hint: "Server-side titles/summaries/chapters" },
  { key: "screenshotApi", label: "Screenshot API", hint: "/api/screenshot/take renders" },
  { key: "teams", label: "Teams", hint: "Share videos into a team library" },
  { key: "sso", label: "Enterprise SSO", hint: "Register an OIDC/SAML identity provider" },
];

export const LIMIT_FIELDS: ReadonlyArray<{ key: string; label: string; unit: string }> = [
  { key: "maxTotalStorageBytes", label: "Total storage", unit: "bytes" },
  { key: "maxFileSizeBytes", label: "Max file size", unit: "bytes" },
  { key: "maxDurationSeconds", label: "Max duration", unit: "seconds" },
  { key: "maxUploadsPerDay", label: "Uploads per day", unit: "per day" },
  { key: "maxScreenshotsPerMonth", label: "Screenshot renders", unit: "per month" },
  { key: "maxHistoryDays", label: "History kept", unit: "days" },
  { key: "maxNamedVersions", label: "Named versions", unit: "per project" },
];

/** A plan as GET /api/admin/plans lists it. */
export interface AdminPlan {
  id: string;
  name: string;
  displayName: string;
  description: string | null;
  priceId: string | null;
  annualPriceId: string | null;
  trialDays: number;
  features: Record<string, boolean>;
  limits: Record<string, number>;
  sortOrder: number;
  isActive: boolean;
  monthlyAmountCents: number | null;
  annualAmountCents: number | null;
  currency: string;
  stripeProductId: string | null;
  popular: boolean;
  saleLabel: string | null;
  salePriceMonthlyCents: number | null;
  salePriceAnnualCents: number | null;
  saleStartsAt: string | null;
  saleEndsAt: string | null;
  saleDurationMonths: number | null;
  stripeSaleCouponId: string | null;
  stripeSaleAnnualCouponId: string | null;
}

/** The body of POST (with `name`) / PUT /api/admin/plans. Amounts in minor
 *  units; a null price = not sold on that interval — or, for a price the
 *  console never knew (an unsynced plan), "keep what Stripe charges". */
export interface PlanInput {
  name?: string;
  displayName: string;
  description: string | null;
  monthlyCents: number | null;
  annualCents: number | null;
  currency: string;
  trialDays: number;
  features: Record<string, boolean>;
  limits: Record<string, number>;
  sortOrder: number;
  isActive: boolean;
  popular: boolean;
  saleLabel: string | null;
  salePriceMonthlyCents: number | null;
  salePriceAnnualCents: number | null;
  saleStartsAt: string | null;
  saleEndsAt: string | null;
  saleDurationMonths: number | null;
}

/** The editor's state: text inputs hold strings (dollars, local times). */
export interface PlanForm {
  id: string | null; // null = creating
  name: string;
  displayName: string;
  description: string;
  monthly: string;
  /** "" = yearly billing off. */
  yearly: string;
  currency: string;
  trialDays: string;
  features: Record<string, boolean>;
  limits: Record<string, number>;
  sortOrder: string;
  isActive: boolean;
  popular: boolean;
  saleLabel: string;
  saleMonthly: string;
  saleYearly: string;
  /** datetime-local values; "" = from saving (start) / none (end). */
  saleStartsAt: string;
  saleEndsAt: string;
  /** "" = for as long as they stay subscribed. */
  saleDurationMonths: string;
}

export const centsToDollars = (c: number | null | undefined) => (c == null ? "" : (c / 100).toString());
export const dollarsToCents = (d: string) => {
  const n = Number.parseFloat(d);
  return d.trim() === "" || !Number.isFinite(n) ? null : Math.round(n * 100);
};

/** ISO → what a datetime-local input shows (local time). */
export function isoToLocal(iso: string | null): string {
  if (!iso) return "";
  const d = new Date(iso);
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
}
export const localToIso = (v: string) => (v.trim() ? new Date(v).toISOString() : null);

/** Months free a yearly price gives against twelve monthly payments. */
export function monthsFreeOf(monthly: string, yearly: string): number | null {
  const m = Number.parseFloat(monthly);
  const y = Number.parseFloat(yearly);
  if (!(m > 0) || !(y > 0)) return null;
  return Math.round((12 - y / m) * 100) / 100;
}

/** The yearly price for `free` months free, in dollars. */
export function yearlyFor(monthly: string, free: number): string {
  const m = Number.parseFloat(monthly);
  return m > 0 ? (Math.round(m * (12 - free) * 100) / 100).toString() : "";
}

/** What the site's Monthly/Annual switch says about the saving. */
export function savingLabel(free: number | null): string | null {
  if (free == null || free <= 0) return null;
  if (Number.isInteger(free)) return `${free} month${free === 1 ? "" : "s"} free`;
  return `Save ${Math.round((free / 12) * 100)}%`;
}

export function emptyForm(): PlanForm {
  return {
    id: null,
    name: "",
    displayName: "",
    description: "",
    monthly: "",
    yearly: "",
    currency: "usd",
    trialDays: "0",
    features: Object.fromEntries(FEATURE_FIELDS.map((f) => [f.key, false])),
    limits: Object.fromEntries(LIMIT_FIELDS.map((l) => [l.key, 0])),
    sortOrder: "100",
    isActive: false,
    popular: false,
    saleLabel: "",
    saleMonthly: "",
    saleYearly: "",
    saleStartsAt: "",
    saleEndsAt: "",
    saleDurationMonths: "",
  };
}

export function formFromPlan(p: AdminPlan): PlanForm {
  return {
    id: p.id,
    name: p.name,
    displayName: p.displayName,
    description: p.description ?? "",
    monthly: centsToDollars(p.monthlyAmountCents),
    yearly: centsToDollars(p.annualAmountCents),
    currency: p.currency || "usd",
    trialDays: String(p.trialDays ?? 0),
    features: Object.fromEntries(FEATURE_FIELDS.map((f) => [f.key, p.features[f.key] === true])),
    limits: Object.fromEntries(LIMIT_FIELDS.map((l) => [l.key, p.limits[l.key] ?? 0])),
    sortOrder: String(p.sortOrder),
    isActive: p.isActive,
    popular: p.popular,
    saleLabel: p.saleLabel ?? "",
    saleMonthly: centsToDollars(p.salePriceMonthlyCents),
    saleYearly: centsToDollars(p.salePriceAnnualCents),
    saleStartsAt: isoToLocal(p.saleStartsAt),
    saleEndsAt: isoToLocal(p.saleEndsAt),
    saleDurationMonths: p.saleDurationMonths ? String(p.saleDurationMonths) : "",
  };
}

export function planInputFromForm(f: PlanForm): PlanInput {
  const yearlyOn = f.yearly.trim() !== "";
  const int = (v: string, fallback: number) => {
    const n = Math.round(Number(v));
    return Number.isFinite(n) && v.trim() !== "" ? n : fallback;
  };
  return {
    ...(f.id ? {} : { name: f.name.trim().toLowerCase() }),
    displayName: f.displayName.trim(),
    description: f.description.trim() || null,
    monthlyCents: dollarsToCents(f.monthly),
    annualCents: yearlyOn ? dollarsToCents(f.yearly) : null,
    currency: f.currency.trim().toLowerCase() || "usd",
    trialDays: Math.max(0, int(f.trialDays, 0)),
    features: f.features,
    limits: Object.fromEntries(LIMIT_FIELDS.map((l) => [l.key, Math.max(0, Math.round(f.limits[l.key] ?? 0))])),
    sortOrder: Math.max(0, int(f.sortOrder, 0)),
    isActive: f.isActive,
    popular: f.popular,
    saleLabel: f.saleLabel.trim() || null,
    salePriceMonthlyCents: dollarsToCents(f.saleMonthly),
    salePriceAnnualCents: yearlyOn ? dollarsToCents(f.saleYearly) : null,
    saleStartsAt: localToIso(f.saleStartsAt),
    saleEndsAt: localToIso(f.saleEndsAt),
    saleDurationMonths: f.saleDurationMonths.trim() ? Math.max(1, int(f.saleDurationMonths, 1)) : null,
  };
}

/** The table's Stripe badge. "Unsynced" = sold (or meant to be) without a
 *  product, or with an amount that has no price behind it. */
export function syncState(p: AdminPlan): "synced" | "unsynced" | null {
  if (p.name === "free") return null;
  if (!p.stripeProductId) return "unsynced";
  if (p.monthlyAmountCents != null && !p.priceId) return "unsynced";
  if (p.annualAmountCents != null && !p.annualPriceId) return "unsynced";
  const sale = p.salePriceMonthlyCents != null || p.salePriceAnnualCents != null;
  const saleOpen = sale && !!p.saleEndsAt && Date.parse(p.saleEndsAt) > Date.now();
  if (saleOpen && !p.stripeSaleCouponId && !p.stripeSaleAnnualCouponId) return "unsynced";
  return "synced";
}

/** "Sale" badge text while a sale is running or scheduled; null otherwise. */
export function saleBadge(p: AdminPlan, now = Date.now()): string | null {
  if (p.salePriceMonthlyCents == null && p.salePriceAnnualCents == null) return null;
  if (!p.saleEndsAt || Date.parse(p.saleEndsAt) <= now) return null;
  const upcoming = p.saleStartsAt && Date.parse(p.saleStartsAt) > now;
  const when = new Date(upcoming ? p.saleStartsAt! : p.saleEndsAt).toLocaleDateString();
  return upcoming ? `Sale from ${when}` : `Sale until ${when}`;
}
