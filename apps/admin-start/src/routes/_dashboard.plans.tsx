import { createFileRoute } from "@tanstack/react-router";

import { PlansTable } from "@/components/admin/plans-table";
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";

export const Route = createFileRoute("/_dashboard/plans")({
  component: PlansPage,
  head: () => ({ meta: [{ title: "Plans — CaptureCat Admin" }] }),
});

function PlansPage() {
  return (
    <div className="space-y-6">
      <Card>
        <CardHeader>
          <CardTitle className="text-2xl">Plans</CardTitle>
          <CardDescription>
            Tiers and the features they unlock. Edits take effect on the next
            request — the API reads plans from the database, so nothing needs
            deploying. A plan with no Stripe price cannot be sold and is only
            used as a fallback tier.
          </CardDescription>
        </CardHeader>
        <CardContent>
          <PlansTable />
        </CardContent>
      </Card>
    </div>
  );
}
