import { createFileRoute } from "@tanstack/react-router";
import { z } from "zod";

import { BillingPageBody } from "@/components/dashboard/account-pages";

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
  return <BillingPageBody success={success === "true"} />;
}
