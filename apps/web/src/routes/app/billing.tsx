import { createFileRoute } from "@tanstack/react-router";
import { z } from "zod";

import { BillingStatus } from "@/components/dashboard/billing-status";
import { PageHeader } from "@/components/dashboard/studio";

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
      <PageHeader
        eyebrow="Account"
        title="Billing"
        description="Your plan, what it includes, and where to change it."
      />
      <BillingStatus success={success === "true"} />
    </div>
  );
}
