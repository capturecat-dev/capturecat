import { createFileRoute } from "@tanstack/react-router";
import { z } from "zod";

import { BillingPageBody } from "@/components/dashboard/account-pages";

// Stripe Checkout returns to `?upgraded=1` (lib/trpc/routers/billing.ts);
// `?success=true` is the older form, still accepted.
const searchSchema = z.object({
  success: z.string().optional(),
  upgraded: z.string().optional(),
});

export const Route = createFileRoute("/app/billing")({
  validateSearch: searchSchema,
  component: BillingPage,
  head: () => ({ meta: [{ title: "Billing — CaptureCat" }] }),
});

function BillingPage() {
  const { success, upgraded } = Route.useSearch();
  return <BillingPageBody success={success === "true" || upgraded === "1"} />;
}
