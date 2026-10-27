import { useState } from "react";
import { createFileRoute } from "@tanstack/react-router";

import { AnalyticsBody, RangePicker, type Days } from "@/components/admin/analytics/analytics-view";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";

export const Route = createFileRoute("/_dashboard/analytics")({
  component: AdminAnalyticsPage,
  head: () => ({ meta: [{ title: "Analytics — CaptureCat Admin" }] }),
});

function AdminAnalyticsPage() {
  const [days, setDays] = useState<Days>(30);
  return (
    <div className="mx-auto flex w-full max-w-7xl flex-col gap-6">
      <Card>
        <CardHeader className="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
          <div className="space-y-1">
            <CardTitle className="text-2xl">Analytics</CardTitle>
            <CardDescription>
              Where users come from, what they do and what they store.
            </CardDescription>
          </div>
          <RangePicker days={days} onChange={setDays} />
        </CardHeader>
        <CardContent>
          <AnalyticsBody days={days} />
        </CardContent>
      </Card>
    </div>
  );
}
