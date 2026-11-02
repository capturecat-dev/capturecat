import { useState } from "react";
import { Check, Minus } from "lucide-react";

import { SubscribeButton } from "./subscribe-button";
import { AIR_CARD, InkLink } from "./airy/primitives";

/** One interval's price. During a sale `amount` is what checkout charges and
 *  `regularAmount` the price struck through (the API decides both, by the
 *  same rule checkout uses). */
interface PriceView {
  amount: number | null;
  currency: string;
  interval: string | null;
  regularAmount?: number | null;
}

/** Shape of GET /api/plans, already fetched by the server component. */
export interface PlanView {
  name: string;
  description: string | null;
  monthly: PriceView;
  annual: PriceView | null;
  /** Only while a sale is on. `durationMonths` null = for as long as you stay. */
  sale?: { label: string; endsAt: string | null; durationMonths: number | null } | null;
  popular?: boolean;
  trialDays: number;
  features: Record<string, boolean> | null;
  /** How long one recording may run on Pro; null = no cap. */
  recordingLimitSeconds?: number | null;
  free: {
    name: string;
    description: string | null;
    features: Record<string, boolean>;
    limits: PlanLimits;
    /** Free is for personal use: each recording stops here (5 min). */
    recordingLimitSeconds?: number | null;
  } | null;
  limits: PlanLimits;
}

interface PlanLimits {
  maxTotalStorageBytes: number;
  maxFileSizeBytes: number;
  maxDurationSeconds: number;
  maxUploadsPerDay?: number;
}

function formatPrice(amount: number | null, currency: string): string {
  if (amount === null) return "n/a";
  return new Intl.NumberFormat("en-US", {
    style: "currency",
    currency: currency.toUpperCase(),
    // Stripe reports minor units; drop the cents when the price is whole.
    minimumFractionDigits: amount % 100 === 0 ? 0 : 2,
  }).format(amount / 100);
}

/** Copy for the gateable feature keys stored on the D1 plan rows. Not
 *  `removeWatermark`: no plan adds a mark to exports, so a dashed "Watermark-free
 *  exports" on Free would contradict its own "no watermark" row. */
const FEATURE_LABELS: Record<string, string> = {
  commercialUse: "Commercial use",
  webCapture: "Capture web pages by URL",
  imageUpload: "Upload screenshots & images",
  cloudShare: "Cloud sharing with links",
  comments: "Timestamped viewer comments",
  teams: "Team library & member invites",
  customStorage: "Share videos from your own S3 bucket",
};

/** Ships with the app on every tier; not gated in D1. */
const CORE_FEATURES = [
  "The full editor, no watermark",
  "Auto zoom & motion effects",
  "Camera overlay & cursor smoothing",
  "On-device captions",
  "Export in full quality",
];

/** How long one recording may run (Free stops each one at 5 min). */
function recordingBullet(seconds: number | null | undefined): string {
  return seconds ? `Recordings up to ${Math.round(seconds / 60)} min each` : "Recordings of any length";
}

function gb(bytes: number): string {
  return `${Math.round(bytes / 1024 ** 3)} GB`;
}

function limitBullets(limits: PlanLimits): string[] {
  const out: string[] = [];
  if (limits.maxTotalStorageBytes > 0) out.push(`${gb(limits.maxTotalStorageBytes)} cloud storage`);
  if (limits.maxDurationSeconds > 0)
    out.push(`Up to ${Math.round(limits.maxDurationSeconds / 60)} min per shared video`);
  return out;
}

function FeatureRow({ label, included }: { label: string; included: boolean }) {
  return (
    <li
      className={`flex items-center gap-3 text-sm ${included ? "" : "text-muted-foreground/50"}`}
    >
      {included ? (
        <Check className="h-4 w-4 shrink-0 text-foreground" />
      ) : (
        <Minus className="h-4 w-4 shrink-0 text-muted-foreground/40" />
      )}
      {label}
    </li>
  );
}

export function PricingCards({ plan }: { plan: PlanView | null }) {
  const [annual, setAnnual] = useState(false);
  const hasAnnual = Boolean(plan?.annual?.amount);
  const showAnnual = annual && hasAnnual;

  const shown = plan ? (showAnnual ? plan.annual! : plan.monthly) : null;
  const price = shown ? formatPrice(shown.amount, shown.currency) : "$10";
  const interval = showAnnual ? "year" : (plan?.monthly.interval ?? "month");
  // A sale on the interval being shown: the regular price is struck through.
  const regular =
    shown && plan?.sale && shown.regularAmount != null ? formatPrice(shown.regularAmount, shown.currency) : null;
  const saleNote =
    regular && plan?.sale
      ? [
          plan.sale.label,
          plan.sale.durationMonths
            ? `first ${plan.sale.durationMonths} month${plan.sale.durationMonths === 1 ? "" : "s"}`
            : "for as long as you stay",
          plan.sale.endsAt
            ? `ends ${new Date(plan.sale.endsAt).toLocaleDateString("en-US", { month: "short", day: "numeric" })}`
            : null,
        ]
          .filter(Boolean)
          .join(" · ")
      : null;

  // Saved-percentage badge — only when both live prices exist. Regular
  // prices, so a sale on one interval doesn't skew the comparison.
  const annualRegular = plan?.annual ? (plan.annual.regularAmount ?? plan.annual.amount) : null;
  const monthlyRegular = plan ? (plan.monthly.regularAmount ?? plan.monthly.amount) : null;
  const savings =
    annualRegular && monthlyRegular ? Math.round((1 - annualRegular / (monthlyRegular * 12)) * 100) : null;

  const gateKeys = Object.keys(FEATURE_LABELS);
  const proGates = plan?.features ?? null;
  const freeGates = plan?.free?.features ?? null;

  return (
    <div className="flex w-full flex-col items-center">
      {hasAnnual && (
        <div className="mb-10 flex items-center gap-1 rounded-full bg-white p-1 text-sm shadow-[0_1px_2px_rgb(0_0_0/0.06)] ring-1 ring-black/[0.08]">
          {(["Monthly", "Annual"] as const).map((label) => {
            const active = label === "Annual" ? annual : !annual;
            return (
              <button
                key={label}
                type="button"
                onClick={() => setAnnual(label === "Annual")}
                className={`rounded-full px-4 py-1.5 transition-colors ${
                  active ? "bg-[var(--cc-air-ink)] text-white" : "text-muted-foreground hover:text-foreground"
                }`}
              >
                {label}
                {label === "Annual" && savings ? (
                  <span className={`ml-1.5 text-xs ${active ? "text-white/60" : ""}`}>
                    −{savings}%
                  </span>
                ) : null}
              </button>
            );
          })}
        </div>
      )}

      <div className="grid w-full max-w-4xl grid-cols-1 gap-6 md:grid-cols-2">
        {/* Free */}
        <div className={`${AIR_CARD} relative p-8`}>
          <h2 className="text-xl font-semibold tracking-[-0.01em]">
            {plan?.free?.name ?? "Free"}
          </h2>
          <p className="mt-1.5 text-sm text-muted-foreground">
            {plan?.free?.description ?? "Personal use. Recordings up to 5 minutes."}
          </p>
          <div className="mt-6">
            <span className="text-5xl font-semibold tracking-[-0.02em]">$0</span>
            <span className="text-muted-foreground"> for personal use</span>
          </div>
          <ul className="mt-8 space-y-3">
            <FeatureRow label={recordingBullet(plan?.free ? plan.free.recordingLimitSeconds : 300)} included />
            {CORE_FEATURES.map((f) => (
              <FeatureRow key={f} label={f} included />
            ))}
            {gateKeys.map((k) => (
              <FeatureRow
                key={k}
                label={FEATURE_LABELS[k]}
                included={freeGates?.[k] ?? false}
              />
            ))}
            {plan?.free && limitBullets(plan.free.limits).map((f) => <FeatureRow key={f} label={f} included />)}
          </ul>
          <InkLink to="/download" className="mt-8 w-full">
            Download for Mac
          </InkLink>
        </div>

        {/* Pro: an ink card, the light pages' dark accent (airy.css puts the
            dark tokens back under data-air-dark). */}
        <div
          data-air-dark
          className="relative isolate overflow-hidden rounded-[24px] bg-[#0b0b10] p-8 text-white shadow-[0_30px_80px_-30px_rgb(40_24_110/0.55)] ring-1 ring-white/10"
        >
          <span
            aria-hidden
            className="absolute inset-0 -z-10 bg-[radial-gradient(70%_50%_at_100%_0%,rgb(124_92_240/0.35),transparent_70%),radial-gradient(60%_40%_at_0%_100%,rgb(47_123_255/0.18),transparent_70%)]"
          />
          <div className="flex items-center justify-between">
            <h2 className="text-xl font-semibold tracking-[-0.01em]">
              {plan?.name ?? "CaptureCat Pro"}
            </h2>
            <div className="flex items-center gap-2">
              {plan?.popular ? (
                <span className="rounded-full bg-white/[0.1] px-3 py-1 text-xs text-white ring-1 ring-white/15">
                  Most popular
                </span>
              ) : null}
              {plan?.trialDays ? (
                <span className="rounded-full bg-white/[0.1] px-3 py-1 text-xs text-white ring-1 ring-white/15">
                  {plan.trialDays}-day free trial
                </span>
              ) : null}
            </div>
          </div>
          <p className="mt-1.5 text-sm text-muted-foreground">
            {plan?.description ?? "Everything you need to record and share"}
          </p>
          <div className="mt-6">
            {regular ? (
              <span className="mr-2 text-2xl text-muted-foreground line-through decoration-1">{regular}</span>
            ) : null}
            <span className="text-5xl font-semibold tracking-[-0.02em]">{price}</span>
            <span className="text-muted-foreground">/{interval}</span>
          </div>
          {saleNote ? <p className="mt-2 text-sm text-muted-foreground">{saleNote}</p> : null}
          <ul className="mt-8 space-y-3">
            <FeatureRow label={recordingBullet(plan?.recordingLimitSeconds)} included />
            {CORE_FEATURES.map((f) => (
              <FeatureRow key={f} label={f} included />
            ))}
            {gateKeys.map((k) => (
              <FeatureRow
                key={k}
                label={FEATURE_LABELS[k]}
                included={proGates?.[k] ?? true}
              />
            ))}
            {plan &&
              limitBullets(plan.limits).map((f) => <FeatureRow key={f} label={f} included />)}
            <FeatureRow label="Views, drop-off & click analytics" included />
            <FeatureRow label="Priority support" included />
          </ul>
          <div className="mt-8">
            <SubscribeButton annual={showAnnual} />
          </div>
        </div>
      </div>
    </div>
  );
}
