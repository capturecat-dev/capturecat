import { useEffect, useState } from "react";
import { CreditCard, Heart, Sparkles } from "lucide-react";
import { API_URL } from "@/lib/api-url";
import { toast } from "sonner";

import { trpc } from "@/lib/trpc/client";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { BillingSkeleton } from "@/components/dashboard/page-skeletons";

export function BillingStatus({ success }: { success: boolean }) {
  const { data, isLoading } = trpc.billing.status.useQuery();

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

  // Live price from the public pricing endpoint (amounts come from Stripe),
  // so a price change never leaves this button lying. Falls back to $10.
  // Three states: unknown (fetch failed — keep the button, just no number),
  // unavailable (Pro hidden in the admin — no button at all), priced.
  const [proPrice, setProPrice] = useState<string | null>(null);
  const [proAvailable, setProAvailable] = useState(true);
  useEffect(() => {
    let cancelled = false;
    void (async () => {
      try {
        const res = await fetch(`${API_URL}/api/plans`);
        if (!res.ok) return;
        const body = (await res.json()) as {
          available?: boolean;
          monthly?: { amount?: number | null; currency?: string };
        };
        if (cancelled) return;
        if (body.available === false) {
          setProAvailable(false);
          return;
        }
        const cents = body.monthly?.amount;
        if (typeof cents === "number") {
          setProPrice(
            new Intl.NumberFormat("en-US", {
              style: "currency",
              currency: (body.monthly?.currency ?? "usd").toUpperCase(),
              maximumFractionDigits: cents % 100 === 0 ? 0 : 2,
            }).format(cents / 100)
          );
        }
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


  return (
    <div className="space-y-6">
      {success && (
        <Card className="border-green-500/50 bg-green-500/10">
          <CardContent className="pt-6">
            <p className="text-sm text-green-600 dark:text-green-400">
              Payment successful! Your account has been upgraded to Pro. Thank
              you — $5 of your subscription is going directly to people in need.
            </p>
          </CardContent>
        </Card>
      )}

      <Card>
        <CardHeader>
          <div className="space-y-1">
            <CardTitle className="flex items-center gap-2">
              Current Plan
              <Badge variant={isPaid ? "default" : "secondary"}>
                {isPaid ? "Pro" : "Free"}
              </Badge>
            </CardTitle>
            <CardDescription>
              {isPaid
                ? "You have full access to all CaptureCat features."
                : "Recording, editing, and export are free forever. Pro adds cloud sharing, AI summaries, team libraries, and custom domains."}
            </CardDescription>
          </div>
        </CardHeader>
        <CardContent className="space-y-4">
          {isPaid ? (
            <div className="flex flex-col sm:flex-row gap-3">
              <Button
                variant="outline"
                onClick={() => createPortal.mutate()}
                disabled={createPortal.isPending}
              >
                <CreditCard className="mr-2 h-4 w-4" />
                {createPortal.isPending ? "Loading..." : "Manage Subscription"}
              </Button>
            </div>
          ) : (
            proAvailable ? (
              <Button
                onClick={() => createCheckout.mutate({ annual: false })}
                disabled={createCheckout.isPending}
              >
                <Sparkles className="mr-2 h-4 w-4" />
                {createCheckout.isPending
                  ? "Redirecting..."
                  : proPrice
                    ? `Upgrade to Pro — ${proPrice}/mo`
                    : "Upgrade to Pro"}
              </Button>
            ) : (
              <p className="text-sm text-muted-foreground">
                Upgrades aren’t available right now — check back soon.
              </p>
            )
          )}
        </CardContent>
      </Card>

      {isPaid && (
        <Card>
          <CardHeader>
            <CardTitle className="flex items-center gap-2 text-base">
              <Heart className="h-4 w-4 text-red-500 fill-red-500" />
              Your Impact
            </CardTitle>
          </CardHeader>
          <CardContent>
            <p className="text-sm text-muted-foreground">
              50% of your subscription ($5/mo) goes directly to people living in
              extreme poverty via{" "}
              <a
                href="https://www.givedirectly.org/"
                target="_blank"
                rel="noopener noreferrer"
                className="underline underline-offset-2 hover:text-foreground transition-colors"
              >
                GiveDirectly
              </a>
              . Thank you for making a difference.
            </p>
          </CardContent>
        </Card>
      )}
    </div>
  );
}
