import { createFileRoute } from "@tanstack/react-router";

import { VideosTable } from "@/components/admin/videos-table";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";

export const Route = createFileRoute("/_dashboard/videos")({
  component: VideosPage,
  head: () => ({ meta: [{ title: "Videos — CaptureCat Admin" }] }),
});

function VideosPage() {
  return (
    <div className="space-y-6">
      <Card>
        <CardHeader>
          <CardTitle className="text-2xl">Videos</CardTitle>
          <CardDescription>
            Every shared video, and what viewers reported from share pages. Taking a video down hides it everywhere
            public and keeps the file, so you can restore it; the owner sees the reason in their dashboard. Deleting is
            permanent.
          </CardDescription>
        </CardHeader>
        <CardContent>
          <VideosTable />
        </CardContent>
      </Card>
    </div>
  );
}
