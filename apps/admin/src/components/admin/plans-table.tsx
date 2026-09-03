import { useState } from "react";
import { MoreHorizontal, Plus } from "lucide-react";

import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { Input } from "@/components/ui/input";
import { Switch } from "@/components/ui/switch";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
  DialogTrigger,
} from "@/components/ui/dialog";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
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

function money(cents: number | null | undefined, currency: string): string | null {
  if (typeof cents !== "number") return null;
  return new Intl.NumberFormat("en-US", {
    style: "currency",
    currency: currency.toUpperCase(),
    maximumFractionDigits: cents % 100 === 0 ? 0 : 2,
  }).format(cents / 100);
}

type Plan = {
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
};

export function PlansTable() {
  const { data, isLoading } = trpc.admin.listPlans.useQuery();
  const [managing, setManaging] = useState<Plan | null>(null);

  if (isLoading) return <TableLoading />;
  const plans = (data?.plans ?? []) as Plan[];

  return (
    <div className="space-y-4">
      <div className="flex justify-end">
        <AddPlanDialog />
      </div>

      <Table>
        <TableHeader>
          <TableRow>
            <TableHead>Plan</TableHead>
            <TableHead>Status</TableHead>
            <TableHead>Features</TableHead>
            <TableHead>Pricing</TableHead>
            <TableHead className="w-10" />
          </TableRow>
        </TableHeader>
        <TableBody>
          {plans.map((plan) => (
            <PlanRow key={plan.id} plan={plan} onManage={() => setManaging(plan)} />
          ))}
        </TableBody>
      </Table>

      {managing && (
        <ManagePlanDialog
          plan={plans.find((p) => p.id === managing.id) ?? managing}
          onClose={() => setManaging(null)}
        />
      )}
    </div>
  );
}

function PlanRow({ plan, onManage }: { plan: Plan; onManage: () => void }) {
  const utils = trpc.useUtils();
  const save = trpc.admin.updatePlan.useMutation({
    onSuccess: () => utils.admin.listPlans.invalidate(),
  });
  const enabled = FEATURES.filter((f) => plan.features[f.key] === true).length;

  return (
    <TableRow className="cursor-pointer" onClick={onManage}>
      <TableCell>
        <span className="font-medium">{plan.displayName}</span>{" "}
        <code className="rounded bg-muted px-1.5 py-0.5 text-xs">{plan.name}</code>
      </TableCell>
      <TableCell>
        <Badge variant={plan.isActive ? "default" : "outline"}>
          {plan.isActive ? "Active" : "Hidden"}
        </Badge>
      </TableCell>
      <TableCell className="text-muted-foreground">
        {enabled}/{FEATURES.length} enabled
      </TableCell>
      <TableCell className="text-muted-foreground">
        {plan.name === "free"
          ? "Free"
          : plan.priceId
            ? [
                money(plan.monthlyAmountCents, plan.currency) ?? "monthly",
                plan.annualPriceId
                  ? `${money(plan.annualAmountCents, plan.currency) ?? "annual"}/yr`
                  : null,
              ]
                .filter(Boolean)
                .join(" · ")
            : "Not sellable"}
        {plan.trialDays > 0 && ` · ${plan.trialDays}d trial`}
      </TableCell>
      <TableCell onClick={(e) => e.stopPropagation()}>
        <DropdownMenu>
          <DropdownMenuTrigger asChild>
            <Button variant="ghost" size="icon" className="h-8 w-8">
              <MoreHorizontal className="h-4 w-4" />
            </Button>
          </DropdownMenuTrigger>
          <DropdownMenuContent align="end">
            <DropdownMenuItem onClick={onManage}>Manage</DropdownMenuItem>
            <DropdownMenuSeparator />
            <DropdownMenuItem
              disabled={save.isPending || plan.name === "free"}
              onClick={() => save.mutate({ ...plan, isActive: !plan.isActive })}
            >
              {plan.isActive ? "Hide from sale" : "Publish"}
            </DropdownMenuItem>
          </DropdownMenuContent>
        </DropdownMenu>
      </TableCell>
    </TableRow>
  );
}

function AddPlanDialog() {
  const utils = trpc.useUtils();
  const [open, setOpen] = useState(false);
  const [name, setName] = useState("");
  const [label, setLabel] = useState("");
  const create = trpc.admin.createPlan.useMutation({
    onSuccess: () => {
      setOpen(false);
      setName("");
      setLabel("");
      utils.admin.listPlans.invalidate();
    },
  });

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>
        <Button size="sm">
          <Plus className="mr-1 h-4 w-4" /> Add plan
        </Button>
      </DialogTrigger>
      <DialogContent className="sm:max-w-sm">
        <DialogHeader>
          <DialogTitle>New plan</DialogTitle>
          <DialogDescription>
            The slug is permanent — it's written onto every subscription row, so
            renaming later would orphan subscribers.
          </DialogDescription>
        </DialogHeader>
        <div className="space-y-3">
          <Input
            placeholder="slug, e.g. business"
            value={name}
            onChange={(e) => setName(e.target.value.toLowerCase().replace(/[^a-z0-9-]/g, ""))}
          />
          <Input
            placeholder="Display name, e.g. Business"
            value={label}
            onChange={(e) => setLabel(e.target.value)}
          />
          {create.error && (
            <p className="text-xs text-destructive">{create.error.message}</p>
          )}
        </div>
        <DialogFooter>
          <Button
            disabled={create.isPending || name.length < 2 || !label.trim()}
            onClick={() => create.mutate({ name, displayName: label.trim() })}
          >
            {create.isPending ? "Creating…" : "Create plan"}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

function ManagePlanDialog({ plan, onClose }: { plan: Plan; onClose: () => void }) {
  const utils = trpc.useUtils();
  const save = trpc.admin.updatePlan.useMutation({
    onSuccess: () => utils.admin.listPlans.invalidate(),
  });
  const saveActive = trpc.admin.updatePlan.useMutation({
    onSuccess: () => utils.admin.listPlans.invalidate(),
  });

  return (
    <Dialog open onOpenChange={(o) => !o && onClose()}>
      <DialogContent className="max-h-[85vh] overflow-y-auto sm:max-w-2xl">
        <DialogHeader>
          <DialogTitle className="flex items-center gap-2">
            {plan.displayName}
            <code className="rounded bg-muted px-1.5 py-0.5 text-xs font-normal">{plan.name}</code>
            <Badge variant={plan.isActive ? "default" : "outline"}>
              {plan.isActive ? "Active" : "Hidden"}
            </Badge>
          </DialogTitle>
          <DialogDescription>
            Changes apply on the next API request — nothing to deploy.
          </DialogDescription>
        </DialogHeader>

        <label className="flex items-center justify-between gap-3 rounded-md border px-3 py-2.5 text-sm">
          <span>
            {plan.isActive ? "Available for sale" : "Hidden from sale"}
            <span className="block text-xs text-muted-foreground">
              {plan.name === "free"
                ? "The free plan is the fallback tier — it can't be hidden."
                : plan.name === "pro" && plan.isActive
                  ? "Careful: hiding Pro breaks the upgrade/checkout flow until re-enabled."
                  : "Hidden plans keep existing subscribers but can't be newly purchased."}
            </span>
          </span>
          <Switch
            checked={plan.isActive}
            disabled={saveActive.isPending || plan.name === "free"}
            onCheckedChange={(on) => saveActive.mutate({ ...plan, isActive: on })}
          />
        </label>

        <div className="grid gap-6 sm:grid-cols-2">
          <div>
            <p className="mb-3 text-sm font-medium">Features</p>
            <div className="space-y-3">
              {FEATURES.map((f) => (
                <label key={f.key} className="flex items-center justify-between gap-3 text-sm">
                  <span>
                    {f.label}
                    <span className="block text-xs text-muted-foreground">{f.hint}</span>
                  </span>
                  <Switch
                    checked={plan.features[f.key] === true}
                    disabled={save.isPending}
                    onCheckedChange={(on) =>
                      save.mutate({ ...plan, features: { ...plan.features, [f.key]: on } })
                    }
                  />
                </label>
              ))}
            </div>
          </div>

          <div className="space-y-6">
            <div>
              <p className="mb-3 text-sm font-medium">Limits</p>
              <div className="space-y-2">
                {LIMITS.map((l) => (
                  <label key={l.key} className="flex items-center gap-2 text-sm">
                    <span className="w-32 shrink-0 text-muted-foreground">{l.label}</span>
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
                  </label>
                ))}
              </div>
            </div>

            {plan.name !== "free" && (
              <div>
                <p className="mb-2 text-sm font-medium">Stripe</p>
                <PriceIdFields plan={plan} />
                <p className="text-xs text-muted-foreground">
                  {money(plan.monthlyAmountCents, plan.currency)
                    ? `${money(plan.monthlyAmountCents, plan.currency)}/mo`
                    : "amount unknown"}
                  {plan.annualPriceId &&
                    ` · ${money(plan.annualAmountCents, plan.currency) ?? "?"}/yr`}
                  <span className="block truncate opacity-60">
                    <code>{plan.priceId ?? "—"}</code>
                  </span>
                </p>

                <StripeSyncRow planId={plan.id} hasPrice={!!plan.priceId} />
              </div>
            )}
          </div>
        </div>
      </DialogContent>
    </Dialog>
  );
}

/** One-click "make it sellable": creates the Stripe product + recurring
 *  price(s) from dollar amounts and writes the price ids back to the plan.
 *  Re-syncing mints NEW prices (existing subscribers keep theirs). */
function StripeSyncRow({ planId, hasPrice }: { planId: string; hasPrice: boolean }) {
  const utils = trpc.useUtils();
  const [monthly, setMonthly] = useState("");
  const [annual, setAnnual] = useState("");
  const [note, setNote] = useState<string | null>(null);
  const sync = trpc.admin.syncPlanStripe.useMutation({
    onSuccess: () => {
      setMonthly("");
      setAnnual("");
      setNote("Prices created in Stripe");
      utils.admin.listPlans.invalidate();
    },
    onError: (e) => setNote(e.message),
  });
  const refresh = trpc.admin.refreshPlanStripe.useMutation({
    onSuccess: () => {
      setNote("Amounts fetched from Stripe");
      utils.admin.listPlans.invalidate();
    },
    onError: (e) => setNote(e.message),
  });
  const toCents = (v: string) => {
    const n = Number(v);
    return Number.isFinite(n) && n > 0 ? Math.round(n * 100) : undefined;
  };
  const hasAmounts = !!(toCents(monthly) || toCents(annual));
  const busy = sync.isPending || refresh.isPending;

  return (
    <div className="mt-2 space-y-2">
      <div className="flex flex-wrap items-center gap-2">
        <Input
          className="h-8 w-24"
          placeholder="$ / month"
          value={monthly}
          onChange={(e) => setMonthly(e.target.value)}
        />
        <Input
          className="h-8 w-24"
          placeholder="$ / year"
          value={annual}
          onChange={(e) => setAnnual(e.target.value)}
        />
        <Button
          size="sm"
          variant="outline"
          disabled={busy || (!hasAmounts && !hasPrice)}
          onClick={() => {
            setNote(null);
            if (hasAmounts) {
              sync.mutate({ planId, monthlyCents: toCents(monthly), annualCents: toCents(annual) });
            } else {
              // No amounts typed: read the CURRENT amounts of the existing
              // price ids out of Stripe instead of minting anything.
              refresh.mutate({ planId });
            }
          }}
        >
          {busy
            ? "Working…"
            : hasAmounts
              ? hasPrice
                ? "Create new prices"
                : "Create in Stripe"
              : "Fetch amounts from Stripe"}
        </Button>
      </div>
      <p className="text-xs text-muted-foreground">
        {note ??
          (hasAmounts
            ? "Creates a new Stripe product + price(s) at these amounts. Existing subscribers keep their old price."
            : hasPrice
              ? "Leave the amounts empty to pull the current amounts of the saved price ids from Stripe."
              : "Enter amounts to create this plan's Stripe product and prices.")}
      </p>
    </div>
  );
}


/** Backfill display amounts for prices minted before amounts were recorded
 *  (or changed directly in the Stripe dashboard). */
function RefreshAmountsButton({ planId }: { planId: string }) {
  const utils = trpc.useUtils();
  const refresh = trpc.admin.refreshPlanStripe.useMutation({
    onSuccess: () => utils.admin.listPlans.invalidate(),
  });
  return (
    <Button
      size="sm"
      variant="ghost"
      className="mt-1 h-7 px-2 text-xs"
      disabled={refresh.isPending}
      onClick={() => refresh.mutate({ planId })}
    >
      {refresh.isPending ? "Fetching…" : "Fetch amounts from Stripe"}
    </Button>
  );
}


/** Paste existing Stripe price ids (price_…) directly — for plans whose
 *  prices were created in the Stripe dashboard rather than the sync button.
 *  Blur saves; follow with "Fetch amounts from Stripe". */
function PriceIdFields({ plan }: { plan: Plan }) {
  const utils = trpc.useUtils();
  const save = trpc.admin.updatePlan.useMutation({
    onSuccess: () => utils.admin.listPlans.invalidate(),
  });
  const commit = (field: "priceId" | "annualPriceId", value: string) => {
    const v = value.trim() || null;
    if (v === plan[field]) return;
    if (v && !/^price_[A-Za-z0-9]+$/.test(v)) return;
    save.mutate({ ...plan, [field]: v });
  };
  return (
    <div className="mb-2 space-y-2">
      <Input
        className="h-8 font-mono text-xs"
        placeholder="price_… (monthly)"
        defaultValue={plan.priceId ?? ""}
        disabled={save.isPending}
        onBlur={(e) => commit("priceId", e.currentTarget.value)}
      />
      <Input
        className="h-8 font-mono text-xs"
        placeholder="price_… (annual, optional)"
        defaultValue={plan.annualPriceId ?? ""}
        disabled={save.isPending}
        onBlur={(e) => commit("annualPriceId", e.currentTarget.value)}
      />
    </div>
  );
}
