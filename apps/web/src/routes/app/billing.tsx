import { createFileRoute } from "@tanstack/react-router";
import { z } from "zod";

import { BillingStatus } from "@/components/dashboard/billing-status";

const searchSchema = z.object({
  success: z.string().optional(),
});

export const Route = createFileRoute("/app/billing")({
  validateSearch: searchSchema,
  component: BillingPage,
  head: () => ({ meta: [{ title: "Billing — CaptureCat" }] }),
});

function BillingPage() {
  const { success } = Route.useSearch();
  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-bold tracking-tight">Billing</h1>
        <p className="text-muted-foreground">
          Manage your subscription and billing.
        </p>
      </div>
      <BillingStatus success={success === "true"} />
    </div>
  );
}
