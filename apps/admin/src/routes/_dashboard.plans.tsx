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
            Tiers, their prices and sales, and the features they unlock.
            Saving a plan syncs it to Stripe — one product per plan, a price
            per interval, a coupon per sale — so nothing is pasted by hand and
            nothing needs deploying. A plan with no price cannot be sold.
          </CardDescription>
        </CardHeader>
        <CardContent>
          <PlansTable />
        </CardContent>
      </Card>
    </div>
  );
}
