import { useEffect, useState, type CSSProperties } from "react";
import { Check, CreditCard, Gauge, HardDrive, Heart, Sparkles } from "lucide-react";
import { API_URL } from "@/lib/api-url";
import { toast } from "sonner";

import { trpc } from "@/lib/trpc/client";
import { Button } from "@/components/ui/button";
import { BillingSkeleton } from "@/components/dashboard/page-skeletons";
import { formatSize } from "@/components/dashboard/video-format";
import { IconKey, LiveDot, Meter, Panel, PlanChip, Section, Sections } from "@/components/dashboard/studio";

type PublicPlans = {
  available?: boolean;
  monthly?: { amount?: number | null; currency?: string };
  limits?: {
    maxTotalStorageBytes?: number;
    maxFileSizeBytes?: number;
    maxDurationSeconds?: number;
    maxUploadsPerDay?: number;
  };
};

function money(cents: number, currency: string) {
  return new Intl.NumberFormat("en-US", {
    style: "currency",
    currency: currency.toUpperCase(),
    maximumFractionDigits: cents % 100 === 0 ? 0 : 2,
  }).format(cents / 100);
}

export function BillingStatus({ success }: { success: boolean }) {
  const { data, isLoading } = trpc.billing.status.useQuery();
  // Storage numbers ride along with the library listing, from the caller's
  // OWN plan row — the same one the upload route enforces.
  const { data: library } = trpc.videos.list.useQuery();

  const createPortal = trpc.billing.portal.useMutation({
    onSuccess: ({ url }: { url?: string }) => {
      if (url) window.location.href = url;
    },
    onError: (err: { message: string }) => {
      toast.error(err.message ?? "Failed to open billing portal");
    },
  });

  const createCheckout = trpc.billing.checkout.useMutation({
    onSuccess: ({ url }: { url?: string }) => {
      if (url) window.location.href = url;
    },
    onError: (err: { message: string }) => {
      toast.error(err.message ?? "Failed to start checkout");
    },
  });

  // Live price + Pro limits from the public pricing endpoint (amounts come
  // from Stripe, limits from the plan table), so this page never lies.
  // Three states: unknown (fetch failed — keep the button, just no number),
  // unavailable (Pro hidden in the admin — no button at all), priced.
  const [pro, setPro] = useState<PublicPlans | null>(null);
  const [proAvailable, setProAvailable] = useState(true);
  useEffect(() => {
    let cancelled = false;
    void (async () => {
      try {
        const res = await fetch(`${API_URL}/api/plans`);
        if (!res.ok) return;
        const body = (await res.json()) as PublicPlans;
        if (cancelled) return;
        if (body.available === false) {
          setProAvailable(false);
          return;
        }
        setPro(body);
      } catch {
        // network failure: keep the button, price unknown
      }
    })();
    return () => {
      cancelled = true;
    };
  }, []);

  if (isLoading) {
    return <BillingSkeleton />;
  }

  const isPaid = data?.tier === "paid";
  const proPrice =
    typeof pro?.monthly?.amount === "number"
      ? money(pro.monthly.amount, pro.monthly.currency ?? "usd")
      : null;

  const used = library?.storageUsedBytes ?? 0;
  const limit = library?.storageLimitBytes ?? 0;
  const ratio = limit > 0 ? Math.min(1, used / limit) : 0;

  return (
    <div className="space-y-4">
      {success && (
        <Panel className="dsh-pop max-w-3xl border-emerald-400/30! bg-emerald-400/[0.07]!" padding="px-5 py-4">
          <p className="flex items-start gap-3 text-sm text-emerald-300">
            <IconKey className="border-emerald-300/30 text-emerald-300">
              <Check />
            </IconKey>
            <span className="pt-1">
              Payment successful — your account is on Pro. Thank you: $5 of your
              subscription goes directly to people in need.
            </span>
          </p>
        </Panel>
      )}

      <Sections className="max-w-3xl">
        <Section
          icon={<Sparkles />}
          title="Current plan"
          badge={
            isPaid ? (
              <span className="inline-flex items-center gap-2">
                <PlanChip plan="pro" />
                <span className="inline-flex items-center gap-1.5 text-[11px] font-medium text-emerald-300">
                  <LiveDot tone="green" className="size-1.5" /> Active
                </span>
              </span>
            ) : undefined
          }
          description={
            isPaid
              ? "Cloud sharing, comments, analytics, AI summaries, team libraries, and custom domains."
              : "Recording, editing, and export are free forever. Pro adds cloud sharing, comments, analytics, AI summaries, team libraries, and custom domains."
          }
        >
          {isPaid ? (
            <Button
              variant="outline"
              onClick={() => createPortal.mutate()}
              disabled={createPortal.isPending}
            >
              <CreditCard data-icon="inline-start" />
              {createPortal.isPending ? "Loading…" : "Manage subscription"}
            </Button>
          ) : proAvailable ? (
            <Button
              onClick={() => createCheckout.mutate({ annual: false })}
              disabled={createCheckout.isPending}
            >
              <Sparkles data-icon="inline-start" />
              {createCheckout.isPending
                ? "Redirecting…"
                : proPrice
                  ? `Upgrade to Pro — ${proPrice}/mo`
                  : "Upgrade to Pro"}
            </Button>
          ) : (
            <p className="text-sm text-muted-foreground">
              Upgrades aren’t available right now — check back soon.
            </p>
          )}
        </Section>

        <Section icon={<HardDrive />} title="Cloud storage" description="Shared videos, every version counted.">
          {limit > 0 ? (
            <>
              <div className="flex items-baseline justify-between gap-3">
                <span className="text-[28px] font-semibold leading-none tabular-nums tracking-[-0.025em]">
                  {formatSize(used)}
                </span>
                <span className="text-xs text-muted-foreground tabular-nums">
                  {Math.round(ratio * 100)}% of {formatSize(limit)}
                </span>
              </div>
              <Meter value={used > 0 ? Math.max(0.01, ratio) : 0} className="mt-4 h-2" />
            </>
          ) : (
            <p className="text-sm text-muted-foreground">
              Your plan has no cloud storage. Upgrade to share from the app.
            </p>
          )}
        </Section>

        {!isPaid && pro?.limits && (
          <Section icon={<Gauge />} title="What Pro includes">
            <dl className="grid grid-cols-2 gap-x-6 gap-y-4 sm:grid-cols-4">
              {[
                ["Cloud storage", formatSize(pro.limits.maxTotalStorageBytes ?? 0)],
                ["Per video", formatSize(pro.limits.maxFileSizeBytes ?? 0)],
                ["Max length", `${Math.round((pro.limits.maxDurationSeconds ?? 0) / 60)} min`],
                ["Shares per day", String(pro.limits.maxUploadsPerDay ?? 0)],
              ].map(([label, value], i) => (
                <div key={label} className="dsh-rise" style={{ "--i": i + 2 } as CSSProperties}>
                  <dt className="studio-eyebrow">{label}</dt>
                  <dd className="mt-1 text-xl font-semibold tabular-nums tracking-[-0.02em]">{value}</dd>
                </div>
              ))}
            </dl>
          </Section>
        )}

        {isPaid && (
          <Section icon={<Heart className="fill-red-500 text-red-500" />} title="Your impact">
          <p className="text-sm text-muted-foreground">
            50% of your subscription ($5/mo) goes directly to people living in
            extreme poverty via{" "}
            <a
              href="https://www.givedirectly.org/"
              target="_blank"
              rel="noopener noreferrer"
              className="text-foreground underline underline-offset-4"
            >
              GiveDirectly
            </a>
            . Thank you for making a difference.
          </p>
          </Section>
        )}
      </Sections>
    </div>
  );
}
