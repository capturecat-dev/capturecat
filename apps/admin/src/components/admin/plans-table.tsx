import { useState } from "react";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { Input } from "@/components/ui/input";
import { trpc } from "@/lib/trpc/client";
import { TableLoading } from "@/components/ui/table-loading";

/** Feature keys the API knows about. Anything else in a plan's JSON is inert,
 *  so the editor shows exactly these rather than whatever a row happens to
 *  contain — a stale key would otherwise look like a working toggle. */
const FEATURES: Array<{ key: string; label: string; hint: string }> = [
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

const LIMITS: Array<{ key: string; label: string; unit: string }> = [
  { key: "maxTotalStorageBytes", label: "Total storage", unit: "bytes" },
  { key: "maxFileSizeBytes", label: "Max file size", unit: "bytes" },
  { key: "maxDurationSeconds", label: "Max duration", unit: "seconds" },
  { key: "maxUploadsPerDay", label: "Uploads per day", unit: "per day" },
  { key: "maxScreenshotsPerMonth", label: "Screenshot renders", unit: "per month" },
];

export function PlansTable() {
  const { data, isLoading } = trpc.admin.listPlans.useQuery();
  const utils = trpc.useUtils();
  const [error, setError] = useState<string | null>(null);
  const [newName, setNewName] = useState("");
  const [newLabel, setNewLabel] = useState("");

  const save = trpc.admin.updatePlan.useMutation({
    onSuccess: () => { setError(null); utils.admin.listPlans.invalidate(); },
    onError: (e) => setError(e.message),
  });
  const create = trpc.admin.createPlan.useMutation({
    onSuccess: () => {
      setError(null); setNewName(""); setNewLabel("");
      utils.admin.listPlans.invalidate();
    },
    onError: (e) => setError(e.message),
  });

  if (isLoading) return <TableLoading />;
  const plans = data?.plans ?? [];

  return (
    <div className="space-y-8">
      {error && <p className="text-sm text-destructive">{error}</p>}

      {plans.map((plan) => (
        <div key={plan.id} className="rounded-lg border p-4">
          <div className="mb-4 flex flex-wrap items-center gap-3">
            <span className="text-lg font-semibold">{plan.displayName}</span>
            {/* The slug, not the label: this is what @better-auth/stripe writes
                onto every subscription row, so it is identity and not editable. */}
            <code className="rounded bg-muted px-1.5 py-0.5 text-xs">{plan.name}</code>
            <Badge variant={plan.isActive ? "default" : "outline"}>
              {plan.isActive ? "Active" : "Hidden"}
            </Badge>
            {!plan.priceId && <Badge variant="outline">No price — not sellable</Badge>}
          </div>

          <div className="grid gap-4 md:grid-cols-2">
            <div>
              <p className="mb-2 text-sm font-medium">Features</p>
              <div className="space-y-2">
                {FEATURES.map((f) => (
                  <label key={f.key} className="flex items-start gap-2 text-sm">
                    <input
                      type="checkbox"
                      className="mt-1"
                      defaultChecked={plan.features[f.key] === true}
                      disabled={save.isPending}
                      onChange={(e) =>
                        save.mutate({
                          ...plan,
                          features: { ...plan.features, [f.key]: e.currentTarget.checked },
                        })
                      }
                    />
                    <span>
                      {f.label}
                      <span className="block text-xs text-muted-foreground">{f.hint}</span>
                    </span>
                  </label>
                ))}
              </div>
            </div>

            <div>
              <p className="mb-2 text-sm font-medium">Limits</p>
              <div className="space-y-2">
                {LIMITS.map((l) => (
                  <label key={l.key} className="flex items-center gap-2 text-sm">
                    <span className="w-36 shrink-0 text-muted-foreground">{l.label}</span>
                    <Input
                      type="number"
                      className="h-8"
                      defaultValue={plan.limits[l.key] ?? 0}
                      disabled={save.isPending}
                      onBlur={(e) => {
                        const next = Number(e.currentTarget.value);
                        if (!Number.isFinite(next) || next === (plan.limits[l.key] ?? 0)) return;
                        save.mutate({ ...plan, limits: { ...plan.limits, [l.key]: next } });
                      }}
                    />
                    <span className="text-xs text-muted-foreground">{l.unit}</span>
                  </label>
                ))}
              </div>
            </div>
          </div>

          <div className="mt-4 flex flex-wrap items-center gap-2">
            <Button
              size="sm"
              variant={plan.isActive ? "outline" : "default"}
              disabled={save.isPending}
              onClick={() => save.mutate({ ...plan, isActive: !plan.isActive })}
            >
              {plan.isActive ? "Hide" : "Publish"}
            </Button>
            <span className="text-xs text-muted-foreground">
              Stripe price: <code>{plan.priceId ?? "—"}</code>
              {plan.annualPriceId && <> · annual: <code>{plan.annualPriceId}</code></>}
              {plan.name !== "free" && <StripeSyncRow planId={plan.id} hasPrice={!!plan.priceId} />}
              {plan.trialDays > 0 && ` · ${plan.trialDays}-day trial`}
            </span>
          </div>
        </div>
      ))}

      <div className="rounded-lg border border-dashed p-4">
        <p className="mb-3 text-sm font-medium">New plan</p>
        <div className="flex flex-wrap items-center gap-2">
          <Input
            placeholder="slug (e.g. team)"
            className="h-9 w-48"
            value={newName}
            onChange={(e) => setNewName(e.target.value)}
          />
          <Input
            placeholder="Display name"
            className="h-9 w-56"
            value={newLabel}
            onChange={(e) => setNewLabel(e.target.value)}
          />
          <Button
            size="sm"
            disabled={create.isPending || newName.length < 2 || !newLabel}
            onClick={() => create.mutate({ name: newName, displayName: newLabel })}
          >
            Create
          </Button>
        </div>
        <p className="mt-2 text-xs text-muted-foreground">
          Created hidden and without a price. The slug is permanent — it is what
          Stripe subscriptions are stored against, so renaming one would orphan
          existing subscribers.
        </p>
      </div>
    </div>
  );
}


/** One-click "make it sellable": creates the Stripe product + recurring
 *  price(s) from dollar amounts and writes the price ids back to the plan.
 *  Re-syncing mints NEW prices (existing subscribers keep theirs). */
function StripeSyncRow({ planId, hasPrice }: { planId: string; hasPrice: boolean }) {
  const utils = trpc.useUtils();
  const [monthly, setMonthly] = useState("");
  const [annual, setAnnual] = useState("");
  const sync = trpc.admin.syncPlanStripe.useMutation({
    onSuccess: () => {
      setMonthly("");
      setAnnual("");
      utils.admin.listPlans.invalidate();
    },
  });
  const toCents = (v: string) => {
    const n = Number(v);
    return Number.isFinite(n) && n > 0 ? Math.round(n * 100) : undefined;
  };

  return (
    <div className="mt-2 flex flex-wrap items-center gap-2">
      <Input
        className="h-8 w-28"
        placeholder="$ / month"
        value={monthly}
        onChange={(e) => setMonthly(e.target.value)}
      />
      <Input
        className="h-8 w-28"
        placeholder="$ / year"
        value={annual}
        onChange={(e) => setAnnual(e.target.value)}
      />
      <Button
        size="sm"
        variant="outline"
        disabled={sync.isPending || (!toCents(monthly) && !toCents(annual))}
        onClick={() =>
          sync.mutate({
            planId,
            monthlyCents: toCents(monthly),
            annualCents: toCents(annual),
          })
        }
      >
        {sync.isPending ? "Syncing…" : hasPrice ? "Re-sync to Stripe" : "Create in Stripe"}
      </Button>
      {sync.error && <span className="text-xs text-destructive">{sync.error.message}</span>}
    </div>
  );
}
