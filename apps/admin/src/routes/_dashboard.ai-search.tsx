import { createFileRoute } from "@tanstack/react-router";

import { AiSearchBody } from "@/components/admin/ai-search/ai-search-view";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";

export const Route = createFileRoute("/_dashboard/ai-search")({
  component: AdminAiSearchPage,
  head: () => ({ meta: [{ title: "AI search — CaptureCat Admin" }] }),
});

function AdminAiSearchPage() {
  return (
    <div className="mx-auto flex w-full max-w-7xl flex-col gap-6">
      <Card>
        <CardHeader className="space-y-1">
          <CardTitle className="text-2xl">AI search</CardTitle>
          <CardDescription>
            The questions buyers ask before choosing a screen recorder, asked of AI engines and Google on a schedule.
            Each lost question says why it's lost and what to change next; rerun to see if it moved.
          </CardDescription>
        </CardHeader>
        <CardContent>
          <AiSearchBody />
        </CardContent>
      </Card>
    </div>
  );
}
