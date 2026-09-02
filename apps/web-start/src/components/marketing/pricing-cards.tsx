import { useState } from "react";
import { Link } from "@tanstack/react-router";
import { Check, Minus } from "lucide-react";

import { SubscribeButton } from "./subscribe-button";

/** Shape of GET /api/plans, already fetched by the server component. */
export interface PlanView {
  name: string;
  description: string | null;
  monthly: { amount: number | null; currency: string; interval: string | null };
  annual: { amount: number | null; currency: string; interval: string | null } | null;
  trialDays: number;
  features: Record<string, boolean> | null;
  free: {
    name: string;
    description: string | null;
    features: Record<string, boolean>;
    limits: PlanLimits;
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
  if (amount === null) return "—";
  return new Intl.NumberFormat("en-US", {
    style: "currency",
    currency: currency.toUpperCase(),
    // Stripe reports minor units; drop the cents when the price is whole.
    minimumFractionDigits: amount % 100 === 0 ? 0 : 2,
  }).format(amount / 100);
}

/** Copy for the gateable feature keys stored on the D1 plan rows. */
const FEATURE_LABELS: Record<string, string> = {
  webCapture: "Capture web pages by URL",
  imageUpload: "Upload screenshots & images",
  cloudShare: "Cloud sharing with links",
  comments: "Timestamped viewer comments",
  removeWatermark: "Watermark-free exports",
};

/** Ships with the app on every tier; not gated in D1. */
const CORE_FEATURES = [
  "Unlimited screen recordings",
  "Auto zoom & motion effects",
  "Camera overlay & cursor smoothing",
  "On-device captions",
  "Export in full quality",
];

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

  const price = plan
    ? showAnnual
      ? formatPrice(plan.annual!.amount, plan.annual!.currency)
      : formatPrice(plan.monthly.amount, plan.monthly.currency)
    : "$10";
  const interval = showAnnual ? "year" : (plan?.monthly.interval ?? "month");

  // Saved-percentage badge — only when both live prices exist.
  const savings =
    plan?.annual?.amount && plan.monthly.amount
      ? Math.round((1 - plan.annual.amount / (plan.monthly.amount * 12)) * 100)
      : null;

  const gateKeys = Object.keys(FEATURE_LABELS);
  const proGates = plan?.features ?? null;
  const freeGates = plan?.free?.features ?? null;

  return (
    <div className="flex w-full flex-col items-center">
      {hasAnnual && (
        <div className="mb-10 flex items-center gap-1 rounded-full border border-white/10 bg-white/[0.05] p-1 text-sm backdrop-blur-2xl">
          {(["Monthly", "Annual"] as const).map((label) => {
            const active = label === "Annual" ? annual : !annual;
            return (
              <button
                key={label}
                type="button"
                onClick={() => setAnnual(label === "Annual")}
                className={`rounded-full px-4 py-1.5 transition-colors ${
                  active ? "bg-white text-black" : "text-muted-foreground hover:text-foreground"
                }`}
              >
                {label}
                {label === "Annual" && savings ? (
                  <span className={`ml-1.5 text-xs ${active ? "text-black/60" : ""}`}>
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
        <div className="relative overflow-hidden rounded-3xl border border-white/10 bg-white/[0.03] p-8 backdrop-blur-2xl">
          <span
            aria-hidden
            className="absolute inset-x-8 top-0 h-px bg-gradient-to-r from-transparent via-white/25 to-transparent"
          />
          <h2 className="text-xl font-semibold tracking-[-0.01em]">
            {plan?.free?.name ?? "Free"}
          </h2>
          <p className="mt-1.5 text-sm text-muted-foreground">
            {plan?.free?.description ?? "The full editor, on your Mac."}
          </p>
          <div className="mt-6">
            <span className="text-5xl font-semibold tracking-[-0.02em]">$0</span>
            <span className="text-muted-foreground"> forever</span>
          </div>
          <ul className="mt-8 space-y-3">
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
          </ul>
          <Link
            to="/download"
            className="mt-8 inline-flex h-11 w-full items-center justify-center rounded-full border border-white/12 bg-white/[0.06] text-[15px] font-medium text-foreground backdrop-blur-xl transition-colors hover:border-white/20 hover:bg-white/[0.10]"
          >
            Download for Mac
          </Link>
        </div>

        {/* Pro */}
        <div className="relative overflow-hidden rounded-3xl border border-white/20 bg-white/[0.06] p-8 shadow-[0_30px_90px_-30px_rgba(0,0,0,0.8)] backdrop-blur-2xl">
          <span
            aria-hidden
            className="absolute inset-x-8 top-0 h-px bg-gradient-to-r from-transparent via-white/50 to-transparent"
          />
          <div className="flex items-center justify-between">
            <h2 className="text-xl font-semibold tracking-[-0.01em]">
              {plan?.name ?? "CaptureCat Pro"}
            </h2>
            {plan?.trialDays ? (
              <span className="rounded-full border border-white/15 bg-white/[0.08] px-3 py-1 text-xs text-foreground">
                {plan.trialDays}-day free trial
              </span>
            ) : null}
          </div>
          <p className="mt-1.5 text-sm text-muted-foreground">
            {plan?.description ?? "Everything you need to record and share"}
          </p>
          <div className="mt-6">
            <span className="text-5xl font-semibold tracking-[-0.02em]">{price}</span>
            <span className="text-muted-foreground">/{interval}</span>
          </div>
          <ul className="mt-8 space-y-3">
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
