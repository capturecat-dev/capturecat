import { useState, type ReactNode } from "react";
import { MoreHorizontal, Plus, RefreshCw } from "lucide-react";
import { toast } from "sonner";

import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { Input } from "@/components/ui/input";
import { Switch } from "@/components/ui/switch";
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
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
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
import { TableLoading } from "@/components/ui/table-loading";
import { trpc } from "@/lib/trpc/client";
import type { PlanSyncSummary, PriceSyncResult } from "@/lib/trpc/routers/admin";
import {
  FEATURE_FIELDS,
  LIMIT_FIELDS,
  emptyForm,
  formFromPlan,
  monthsFreeOf,
  planInputFromForm,
  saleBadge,
  savingLabel,
  syncState,
  yearlyFor,
  type AdminPlan,
  type PlanForm,
} from "@/lib/plan-fields";

function money(cents: number | null | undefined, currency: string): string | null {
  if (typeof cents !== "number") return null;
  return new Intl.NumberFormat("en-US", {
    style: "currency",
    currency: currency.toUpperCase(),
    maximumFractionDigits: cents % 100 === 0 ? 0 : 2,
  }).format(cents / 100);
}

type SyncAllResult = { planId: string; plan: string; summary?: PlanSyncSummary; skipped?: string; error?: string };

export function PlansTable() {
  const { data, isLoading } = trpc.admin.listPlans.useQuery();
  // null = closed; "new" = creating; otherwise the plan id being edited.
  const [editing, setEditing] = useState<string | null>(null);
  const [results, setResults] = useState<SyncAllResult[] | null>(null);

  if (isLoading) return <TableLoading />;
  const plans = (data?.plans ?? []) as AdminPlan[];
  const stripeConfigured = data?.stripeConfigured ?? false;
  const editingPlan = editing && editing !== "new" ? plans.find((p) => p.id === editing) ?? null : null;

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-center justify-end gap-2">
        <SyncAllButton disabled={!stripeConfigured} onDone={setResults} />
        <Button size="sm" onClick={() => setEditing("new")}>
          <Plus className="mr-1 h-4 w-4" /> New plan
        </Button>
      </div>

      {!stripeConfigured && (
        <p className="rounded-md border border-amber-500/40 bg-amber-500/5 px-3 py-2 text-sm text-muted-foreground">
          Stripe isn't configured (no <code>STRIPE_SECRET_KEY</code>). Features and limits still save; prices
          and sales can't change until it is set.
        </p>
      )}

      <Table>
        <TableHeader>
          <TableRow>
            <TableHead>Plan</TableHead>
            <TableHead>Price</TableHead>
            <TableHead>Features</TableHead>
            <TableHead>Status</TableHead>
            <TableHead className="w-10" />
          </TableRow>
        </TableHeader>
        <TableBody>
          {plans.map((plan) => (
            <PlanRow
              key={plan.id}
              plan={plan}
              stripeConfigured={stripeConfigured}
              onEdit={() => setEditing(plan.id)}
              onSynced={(summary) => setResults([{ planId: plan.id, plan: plan.name, summary }])}
            />
          ))}
        </TableBody>
      </Table>

      {editing && (
        <PlanEditorDialog
          key={editing}
          plan={editingPlan}
          stripeConfigured={stripeConfigured}
          onClose={() => setEditing(null)}
        />
      )}

      {results && <SyncResultsDialog results={results} onClose={() => setResults(null)} />}
    </div>
  );
}

function PriceCell({ plan }: { plan: AdminPlan }) {
  if (plan.name === "free") return <>Free</>;
  const monthly = money(plan.monthlyAmountCents, plan.currency);
  const yearly = money(plan.annualAmountCents, plan.currency);
  if (!monthly && !yearly) return <>{plan.stripeProductId ? "Not sold" : "Not synced"}</>;
  const saleMonthly = money(plan.salePriceMonthlyCents, plan.currency);
  return (
    <>
      {monthly && `${monthly}/mo`}
      {monthly && yearly && " · "}
      {yearly && `${yearly}/yr`}
      {saleBadge(plan) && saleMonthly && <span className="block text-xs">sale {saleMonthly}/mo</span>}
      {plan.trialDays > 0 && <span className="block text-xs">{plan.trialDays}-day trial</span>}
    </>
  );
}

function PlanRow({
  plan,
  stripeConfigured,
  onEdit,
  onSynced,
}: {
  plan: AdminPlan;
  stripeConfigured: boolean;
  onEdit: () => void;
  onSynced: (summary: PlanSyncSummary) => void;
}) {
  const utils = trpc.useUtils();
  const [confirmHide, setConfirmHide] = useState(false);
  const refresh = () => utils.admin.listPlans.invalidate();
  const setActive = trpc.admin.setPlanActive.useMutation({
    onSuccess: (_d, v) => {
      refresh();
      toast.success(v.isActive ? `${plan.displayName} is on sale` : `${plan.displayName} is hidden from sale`);
    },
    onError: (e) => toast.error(e.message),
  });
  const setPopular = trpc.admin.setPlanPopular.useMutation({
    onSuccess: refresh,
    onError: (e) => toast.error(e.message),
  });
  const sync = trpc.admin.syncPlanStripe.useMutation({
    onSuccess: ({ summary }) => {
      refresh();
      onSynced(summary);
    },
    onError: (e) => toast.error(e.message),
  });
  const enabled = FEATURE_FIELDS.filter((f) => plan.features[f.key] === true).length;
  const state = syncState(plan);
  const sale = saleBadge(plan);

  return (
    <TableRow className="cursor-pointer" onClick={onEdit}>
      <TableCell>
        <span className="font-medium">{plan.displayName}</span>{" "}
        <code className="rounded bg-muted px-1.5 py-0.5 text-xs">{plan.name}</code>
      </TableCell>
      <TableCell className="text-muted-foreground">
        <PriceCell plan={plan} />
      </TableCell>
      <TableCell className="text-muted-foreground">
        {enabled}/{FEATURE_FIELDS.length} enabled
      </TableCell>
      <TableCell>
        <div className="flex flex-wrap gap-1">
          <Badge variant={plan.isActive ? "default" : "outline"}>{plan.isActive ? "Active" : "Hidden"}</Badge>
          {state === "synced" && <Badge variant="secondary">Synced</Badge>}
          {state === "unsynced" && (
            <Badge variant="destructive" title="Not yet in step with Stripe: open ⋯ → Sync with Stripe, or save the plan.">
              Unsynced
            </Badge>
          )}
          {sale && <Badge variant="outline">{sale}</Badge>}
          {plan.popular && <Badge variant="secondary">Most popular</Badge>}
        </div>
      </TableCell>
      <TableCell onClick={(e) => e.stopPropagation()}>
        <DropdownMenu modal={false}>
          <DropdownMenuTrigger asChild>
            <Button variant="ghost" size="icon" className="h-8 w-8" aria-label={`Actions for ${plan.displayName}`}>
              <MoreHorizontal className="h-4 w-4" />
            </Button>
          </DropdownMenuTrigger>
          <DropdownMenuContent align="end">
            <DropdownMenuItem onClick={onEdit}>Edit…</DropdownMenuItem>
            {plan.name !== "free" && (
              <DropdownMenuItem disabled={!stripeConfigured || sync.isPending} onClick={() => sync.mutate({ planId: plan.id })}>
                {sync.isPending ? "Syncing…" : "Sync with Stripe"}
              </DropdownMenuItem>
            )}
            {plan.name !== "free" && (
              <DropdownMenuItem
                disabled={setPopular.isPending}
                onClick={() => setPopular.mutate({ id: plan.id, popular: !plan.popular })}
              >
                {plan.popular ? "Unmark most popular" : "Mark most popular"}
              </DropdownMenuItem>
            )}
            <DropdownMenuSeparator />
            {plan.isActive ? (
              <DropdownMenuItem
                disabled={setActive.isPending || plan.name === "free"}
                onClick={() => setConfirmHide(true)}
              >
                Hide from sale…
              </DropdownMenuItem>
            ) : (
              <DropdownMenuItem disabled={setActive.isPending} onClick={() => setActive.mutate({ id: plan.id, isActive: true })}>
                Publish
              </DropdownMenuItem>
            )}
          </DropdownMenuContent>
        </DropdownMenu>
        <HideConfirm
          open={confirmHide}
          onOpenChange={setConfirmHide}
          plan={plan}
          onConfirm={() => setActive.mutate({ id: plan.id, isActive: false })}
        />
      </TableCell>
    </TableRow>
  );
}

/** Hiding is not cancelling: say exactly what it does before doing it. */
function HideConfirm({
  open,
  onOpenChange,
  plan,
  onConfirm,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  plan: AdminPlan;
  onConfirm: () => void;
}) {
  return (
    <AlertDialog open={open} onOpenChange={onOpenChange}>
      <AlertDialogContent>
        <AlertDialogHeader>
          <AlertDialogTitle>Hide {plan.displayName} from sale?</AlertDialogTitle>
          <AlertDialogDescription>
            New purchases stop: the plan leaves checkout and the pricing page. Everyone already subscribed keeps
            its features until their subscription ends, and nothing changes in Stripe. You can publish it again
            at any time.
          </AlertDialogDescription>
        </AlertDialogHeader>
        <AlertDialogFooter>
          <AlertDialogCancel>Cancel</AlertDialogCancel>
          <AlertDialogAction variant="destructive" onClick={onConfirm}>
            Hide from sale
          </AlertDialogAction>
        </AlertDialogFooter>
      </AlertDialogContent>
    </AlertDialog>
  );
}

function SyncAllButton({ disabled, onDone }: { disabled: boolean; onDone: (r: SyncAllResult[]) => void }) {
  const utils = trpc.useUtils();
  const [open, setOpen] = useState(false);
  const syncAll = trpc.admin.syncAllPlans.useMutation({
    onSuccess: ({ results }) => {
      utils.admin.listPlans.invalidate();
      onDone(results);
    },
    onError: (e) => toast.error(e.message),
  });
  return (
    <>
      <Button size="sm" variant="outline" disabled={disabled || syncAll.isPending} onClick={() => setOpen(true)}>
        <RefreshCw className={`mr-1 h-4 w-4 ${syncAll.isPending ? "animate-spin" : ""}`} />
        {syncAll.isPending ? "Syncing…" : "Sync all plans"}
      </Button>
      <AlertDialog open={open} onOpenChange={setOpen}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>Sync every plan with Stripe?</AlertDialogTitle>
            <AlertDialogDescription>
              Each paid plan gets its one Stripe product and a price per interval, found by lookup key. Prices
              Stripe already charges are kept (an un-keyed one is adopted in place), so nobody's subscription
              moves. Plans with no price yet are skipped; Free is never sold. Running it twice changes nothing.
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>Cancel</AlertDialogCancel>
            <AlertDialogAction onClick={() => syncAll.mutate()}>Sync all plans</AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </>
  );
}

const PRICE_ACTION: Record<PriceSyncResult["action"], { label: string; variant: "default" | "secondary" | "outline" | "destructive" }> = {
  adopted: { label: "Adopted", variant: "default" },
  created: { label: "Created", variant: "default" },
  reused: { label: "Reused", variant: "secondary" },
  archived: { label: "Archived", variant: "destructive" },
  none: { label: "No price", variant: "outline" },
};

/** One plan's sync, per interval: what happened to the price and the sale. */
export function SyncSummaryView({ summary }: { summary: PlanSyncSummary }) {
  const line = (r: PriceSyncResult) => {
    const a = PRICE_ACTION[r.action];
    const amount = r.amountCents != null && r.currency ? money(r.amountCents, r.currency) : null;
    return (
      <li key={r.interval} className="flex flex-wrap items-center gap-x-2 gap-y-1">
        <span className="w-16 shrink-0 text-muted-foreground">{r.interval === "month" ? "Monthly" : "Yearly"}</span>
        <Badge variant={a.variant}>{a.label}</Badge>
        {amount && <span>{amount}</span>}
        {r.priceId && <code className="text-xs text-muted-foreground">{r.priceId}</code>}
        {r.adoptedFrom && <span className="text-xs text-muted-foreground">from the {r.adoptedFrom === "env" ? "env secret" : "plan row"}</span>}
        {r.archived && r.action !== "archived" && (
          <span className="text-xs text-muted-foreground">
            archived <code>{r.archived}</code>
          </span>
        )}
        {r.coupon.action !== "none" && (
          <span className="text-xs text-muted-foreground">
            {r.coupon.action === "reused"
              ? "Sale coupon kept"
              : r.coupon.action === "deleted"
                ? "Sale coupon deleted"
                : r.coupon.replaced
                  ? `Sale coupon replaced (${r.coupon.replaced} → ${r.coupon.id})`
                  : "Sale coupon created"}
          </span>
        )}
      </li>
    );
  };
  return (
    <div className="space-y-2 text-sm">
      <p className="flex flex-wrap items-center gap-2">
        <span className="text-muted-foreground">Product</span>
        <Badge variant={summary.product.action === "unchanged" ? "secondary" : "default"}>
          {summary.product.action === "created" ? "Created" : summary.product.action === "updated" ? "Updated" : "Unchanged"}
        </Badge>
        <code className="text-xs text-muted-foreground">{summary.product.id}</code>
        {!summary.changed && <span className="text-xs text-muted-foreground">Already in sync — nothing changed.</span>}
      </p>
      <ul className="space-y-1.5">
        {line(summary.monthly)}
        {line(summary.annual)}
      </ul>
      {summary.notes.length > 0 && (
        <ul className="list-disc space-y-0.5 pl-5 text-xs text-muted-foreground">
          {summary.notes.map((n) => (
            <li key={n}>{n}</li>
          ))}
        </ul>
      )}
    </div>
  );
}

function SyncResultsDialog({ results, onClose }: { results: SyncAllResult[]; onClose: () => void }) {
  return (
    <Dialog open onOpenChange={(o) => !o && onClose()}>
      <DialogContent className="max-h-[85vh] overflow-y-auto sm:max-w-xl">
        <DialogHeader>
          <DialogTitle>Stripe sync</DialogTitle>
          <DialogDescription>What each plan's sync did in Stripe.</DialogDescription>
        </DialogHeader>
        <div className="divide-y">
          {results.map((r) => (
            <div key={r.planId} className="space-y-2 py-3 first:pt-0 last:pb-0">
              <p className="font-medium">
                <code className="rounded bg-muted px-1.5 py-0.5 text-xs">{r.plan}</code>
              </p>
              {r.summary && <SyncSummaryView summary={r.summary} />}
              {r.skipped && <p className="text-sm text-muted-foreground">Skipped: {r.skipped}</p>}
              {r.error && <p className="text-sm text-destructive">{r.error}</p>}
            </div>
          ))}
        </div>
        <DialogFooter>
          <Button onClick={onClose}>Done</Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

function Field({ label, hint, children, htmlFor }: { label: string; hint?: ReactNode; children: ReactNode; htmlFor?: string }) {
  return (
    <div className="space-y-1.5">
      <label htmlFor={htmlFor} className="text-xs font-medium text-muted-foreground">
        {label}
      </label>
      {children}
      {hint && <p className="text-xs text-muted-foreground">{hint}</p>}
    </div>
  );
}

function Section({ title, description, children }: { title: string; description?: ReactNode; children: ReactNode }) {
  return (
    <section className="space-y-3 border-t pt-5 first:border-t-0 first:pt-0">
      <div>
        <h3 className="text-sm font-medium">{title}</h3>
        {description && <p className="mt-1 text-xs text-muted-foreground">{description}</p>}
      </div>
      {children}
    </section>
  );
}

/**
 * One dialog for creating and editing a plan, after the owner's other app.
 * SAVE IS SYNC: the API provisions Stripe (product, keyed prices, sale
 * coupons) and only then writes the plan; the summary of what it did shows
 * here afterwards.
 */
function PlanEditorDialog({
  plan,
  stripeConfigured,
  onClose,
}: {
  plan: AdminPlan | null;
  stripeConfigured: boolean;
  onClose: () => void;
}) {
  const utils = trpc.useUtils();
  // The plan as last saved: the prop, then whatever each save returned (so a
  // just-created plan edits as itself).
  const [saved, setSaved] = useState<AdminPlan | null>(plan);
  const [form, setForm] = useState<PlanForm>(() => (plan ? formFromPlan(plan) : emptyForm()));
  const [yearlyOn, setYearlyOn] = useState(() => form.yearly.trim() !== "");
  const [summary, setSummary] = useState<PlanSyncSummary | null>(null);
  const [error, setError] = useState<string | null>(null);
  const create = trpc.admin.createPlan.useMutation();
  const update = trpc.admin.updatePlan.useMutation();
  const saving = create.isPending || update.isPending;
  const isFree = form.name === "free";
  const set = (patch: Partial<PlanForm>) => setForm((f) => ({ ...f, ...patch }));

  async function save() {
    setError(null);
    const input = planInputFromForm({ ...form, yearly: yearlyOn ? form.yearly : "", saleYearly: yearlyOn ? form.saleYearly : "" });
    try {
      const res = form.id
        ? await update.mutateAsync({ id: form.id, ...input })
        : await create.mutateAsync({ ...input, name: input.name ?? form.name });
      await utils.admin.listPlans.invalidate();
      setSaved(res.plan);
      setForm(formFromPlan(res.plan));
      setYearlyOn(res.plan.annualAmountCents != null);
      setSummary(res.summary);
      toast.success(form.id ? "Plan saved" : "Plan created", {
        description: res.summary ? (res.summary.changed ? "Synced with Stripe." : "Stripe was already in sync.") : undefined,
      });
    } catch (e) {
      setError(e instanceof Error ? e.message : "Could not save the plan");
    }
  }

  const free = monthsFreeOf(form.monthly, form.yearly);
  const saving_ = savingLabel(free);
  const unsynced = !!saved && !isFree && !saved.stripeProductId;

  return (
    <Dialog open onOpenChange={(o) => !o && onClose()}>
      <DialogContent className="max-h-[90vh] overflow-y-auto sm:max-w-2xl">
        <DialogHeader>
          <DialogTitle className="flex items-center gap-2">
            {saved ? saved.displayName : "New plan"}
            {saved && <code className="rounded bg-muted px-1.5 py-0.5 text-xs font-normal">{saved.name}</code>}
          </DialogTitle>
          <DialogDescription>
            {isFree
              ? "The fallback tier every signed-in user without a subscription gets. Never sold."
              : "Saving updates Stripe first — the product, a price per interval and the sale coupons — then the plan. Changes reach the app on the next request."}
          </DialogDescription>
        </DialogHeader>

        <div className="space-y-5">
          <Section title="Plan">
            <div className="grid gap-3 sm:grid-cols-2">
              <Field label="Display name" htmlFor="p-name">
                <Input id="p-name" placeholder="CaptureCat Pro" value={form.displayName} onChange={(e) => set({ displayName: e.target.value })} />
              </Field>
              <Field label="Slug" htmlFor="p-slug" hint={saved ? "Permanent: it's on every subscription." : "Permanent once created."}>
                <Input
                  id="p-slug"
                  placeholder="business"
                  value={form.name}
                  disabled={!!saved}
                  onChange={(e) => set({ name: e.target.value.toLowerCase().replace(/[^a-z0-9_-]/g, "") })}
                />
              </Field>
            </div>
            <Field label="Description" htmlFor="p-desc">
              <textarea
                id="p-desc"
                rows={2}
                className="w-full min-w-0 rounded-2xl border border-input bg-input/30 px-3 py-2 text-sm outline-none placeholder:text-muted-foreground focus-visible:border-ring focus-visible:ring-[3px] focus-visible:ring-ring/50"
                placeholder="What this tier is for."
                value={form.description}
                onChange={(e) => set({ description: e.target.value })}
              />
            </Field>
          </Section>

          {!isFree && (
            <Section
              title="Price"
              description={
                unsynced
                  ? "Not synced with Stripe yet. Leave the prices blank to adopt what Stripe already charges for this plan (for Pro, the price in STRIPE_PRO_PRICE_ID) — no new price, nobody moved — or type new ones."
                  : "A changed price creates a new Stripe price and archives the old one. People already subscribed keep paying the price they joined at."
              }
            >
              <div className="grid gap-3 sm:grid-cols-3">
                <Field label="Monthly price" htmlFor="p-mo">
                  <Input id="p-mo" type="number" min={0} step="0.01" placeholder={unsynced ? "Keep Stripe's" : "10"} value={form.monthly} disabled={!stripeConfigured} onChange={(e) => set({ monthly: e.target.value })} />
                </Field>
                <Field label="Currency" htmlFor="p-cur">
                  <Input id="p-cur" maxLength={3} value={form.currency} disabled={!stripeConfigured} onChange={(e) => set({ currency: e.target.value.toLowerCase().replace(/[^a-z]/g, "") })} />
                </Field>
                <Field label="Trial days" htmlFor="p-trial">
                  <Input id="p-trial" type="number" min={0} max={365} value={form.trialDays} onChange={(e) => set({ trialDays: e.target.value })} />
                </Field>
              </div>

              <div className="space-y-3 rounded-2xl border p-3">
                <label className="flex items-start justify-between gap-3 text-sm">
                  <span>
                    Yearly billing
                    <span className="block text-xs text-muted-foreground">
                      Off: monthly only. Turning it off archives the yearly price; people already on it keep it.
                    </span>
                  </span>
                  <Switch
                    checked={yearlyOn}
                    disabled={!stripeConfigured}
                    onCheckedChange={(on) => {
                      setYearlyOn(on);
                      set(on ? { yearly: form.yearly || yearlyFor(form.monthly, 2) } : { yearly: "", saleYearly: "" });
                    }}
                  />
                </label>
                {yearlyOn && (
                  <>
                    <Field label="Months free">
                      <div className="flex flex-wrap gap-1">
                        {[0, 1, 2, 3, 4, 5, 6].map((n) => (
                          <Button
                            key={n}
                            type="button"
                            size="xs"
                            variant={free === n ? "default" : "outline"}
                            disabled={!form.monthly.trim()}
                            onClick={() => set({ yearly: yearlyFor(form.monthly, n) })}
                          >
                            {n === 0 ? "None" : n}
                          </Button>
                        ))}
                        {free != null && !(Number.isInteger(free) && free >= 0 && free <= 6) && (
                          <Badge variant="outline">Custom</Badge>
                        )}
                      </div>
                    </Field>
                    <Field
                      label="Yearly price"
                      htmlFor="p-yr"
                      hint={saving_ ? `The site shows "${saving_}" beside the yearly price.` : "No saving shown: it's twelve monthly payments."}
                    >
                      <Input id="p-yr" type="number" min={0} step="0.01" placeholder={unsynced ? "Keep Stripe's" : ""} value={form.yearly} onChange={(e) => set({ yearly: e.target.value })} />
                    </Field>
                  </>
                )}
              </div>
            </Section>
          )}

          {!isFree && (
            <Section
              title="Sale"
              description="A price for a period. Between these dates checkout adds a Stripe coupon that takes the regular price down to the sale price, and the site shows the regular price struck through. The coupon can't be redeemed after the end, so Stripe itself stops it. An end date is required; leave the prices blank for no sale."
            >
              <div className="grid gap-3 sm:grid-cols-3">
                <Field label="Label" htmlFor="p-sale-label">
                  <Input id="p-sale-label" placeholder="Launch price" maxLength={40} value={form.saleLabel} onChange={(e) => set({ saleLabel: e.target.value })} />
                </Field>
                <Field label="Sale monthly price" htmlFor="p-sale-mo">
                  <Input id="p-sale-mo" type="number" min={0} step="0.01" value={form.saleMonthly} disabled={!stripeConfigured} onChange={(e) => set({ saleMonthly: e.target.value })} />
                </Field>
                <Field label="Sale yearly price" htmlFor="p-sale-yr">
                  <Input
                    id="p-sale-yr"
                    type="number"
                    min={0}
                    step="0.01"
                    placeholder={yearlyOn ? "" : "Yearly billing is off"}
                    disabled={!yearlyOn || !stripeConfigured}
                    value={form.saleYearly}
                    onChange={(e) => set({ saleYearly: e.target.value })}
                  />
                </Field>
              </div>
              <div className="grid gap-3 sm:grid-cols-3">
                <Field label="Starts" htmlFor="p-sale-start" hint="Blank: as soon as it's saved.">
                  <Input id="p-sale-start" type="datetime-local" value={form.saleStartsAt} onChange={(e) => set({ saleStartsAt: e.target.value })} />
                </Field>
                <Field label="Ends" htmlFor="p-sale-end">
                  <Input id="p-sale-end" type="datetime-local" value={form.saleEndsAt} onChange={(e) => set({ saleEndsAt: e.target.value })} />
                </Field>
                <Field label="Discount lasts (months)" htmlFor="p-sale-months">
                  <Input id="p-sale-months" type="number" min={1} max={36} placeholder="Forever" value={form.saleDurationMonths} onChange={(e) => set({ saleDurationMonths: e.target.value })} />
                </Field>
              </div>
              <p className="text-xs text-muted-foreground">
                {form.saleDurationMonths.trim()
                  ? `People who join during the sale get it for their first ${form.saleDurationMonths.trim()} month${form.saleDurationMonths.trim() === "1" ? "" : "s"}, then pay the regular price.`
                  : "People who join during the sale keep the sale price for as long as they stay subscribed."}
              </p>
            </Section>
          )}

          <Section title="Features">
            <div className="space-y-3">
              {FEATURE_FIELDS.map((f) => (
                <label key={f.key} className="flex items-center justify-between gap-3 text-sm">
                  <span>
                    {f.label}
                    <span className="block text-xs text-muted-foreground">{f.hint}</span>
                  </span>
                  <Switch
                    checked={form.features[f.key] === true}
                    onCheckedChange={(on) => set({ features: { ...form.features, [f.key]: on } })}
                  />
                </label>
              ))}
            </div>
          </Section>

          <Section title="Limits" description="0 means none.">
            <div className="grid gap-3 sm:grid-cols-2">
              {LIMIT_FIELDS.map((l) => (
                <Field key={l.key} label={`${l.label} (${l.unit})`} htmlFor={`lim-${l.key}`}>
                  <Input
                    id={`lim-${l.key}`}
                    type="number"
                    min={0}
                    className="h-8"
                    value={form.limits[l.key] ?? 0}
                    onChange={(e) => set({ limits: { ...form.limits, [l.key]: Number(e.target.value) || 0 } })}
                  />
                </Field>
              ))}
            </div>
          </Section>

          <Section title="Visibility">
            <div className="flex flex-wrap items-center gap-6 text-sm">
              <label className="flex items-center gap-2">
                <Switch checked={form.isActive} disabled={isFree} onCheckedChange={(on) => set({ isActive: on })} />
                Active
              </label>
              {!isFree && (
                <label className="flex items-center gap-2">
                  <Switch checked={form.popular} onCheckedChange={(on) => set({ popular: on })} />
                  Most popular
                </label>
              )}
              <label className="flex items-center gap-2">
                Order
                <Input type="number" min={0} className="h-8 w-20" value={form.sortOrder} onChange={(e) => set({ sortOrder: e.target.value })} />
              </label>
            </div>
            {!isFree && !form.isActive && saved?.isActive && (
              <p className="text-xs text-muted-foreground">
                Hiding stops new purchases only. Everyone already subscribed keeps this plan's features until their
                subscription ends.
              </p>
            )}
          </Section>

          {summary && (
            <Section title="Stripe">
              <SyncSummaryView summary={summary} />
            </Section>
          )}
          {error && <p className="text-sm text-destructive">{error}</p>}
        </div>

        <DialogFooter>
          <Button variant="outline" onClick={onClose}>
            {summary ? "Done" : "Cancel"}
          </Button>
          <Button onClick={save} disabled={saving || !form.displayName.trim() || form.name.trim().length < 2}>
            {saving ? "Saving…" : saved ? (isFree || !stripeConfigured ? "Save" : "Save & sync") : "Create plan"}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
