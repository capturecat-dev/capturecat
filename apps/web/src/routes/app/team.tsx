import { createFileRoute } from "@tanstack/react-router";

import { PageHeader } from "@/components/dashboard/studio";
import { TeamCards } from "@/components/dashboard/team-cards";

export const Route = createFileRoute("/app/team")({
  component: TeamPage,
  head: () => ({ meta: [{ title: "Team — CaptureCat" }] }),
});

function TeamPage() {
  return (
    <div className="space-y-6">
      <PageHeader
        eyebrow="Workspace"
        title="Team"
        description="A shared library for your company, who is in it, and how they sign in."
      />
      <TeamCards />
    </div>
  );
}
