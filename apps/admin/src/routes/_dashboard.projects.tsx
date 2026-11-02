import { createFileRoute } from "@tanstack/react-router";

import { ProjectsTable } from "@/components/admin/projects-table";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";

export const Route = createFileRoute("/_dashboard/projects")({
  component: ProjectsPage,
  head: () => ({ meta: [{ title: "Projects — CaptureCat Admin" }] }),
});

function ProjectsPage() {
  return (
    <div className="space-y-6">
      <Card>
        <CardHeader>
          <CardTitle className="text-2xl">Projects</CardTitle>
          <CardDescription>
            Every project users have on CaptureCat: each web recording, and each Mac project someone opened in the web
            editor. “Never shared” is a recording with no share link. Recordings that stay on a Mac never reach the
            server, so they aren&apos;t here.
          </CardDescription>
        </CardHeader>
        <CardContent>
          <ProjectsTable />
        </CardContent>
      </Card>
    </div>
  );
}
