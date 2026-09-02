import { createFileRoute } from "@tanstack/react-router";

import { TeamCards } from "@/components/dashboard/team-cards";

export const Route = createFileRoute("/app/team")({
  component: TeamPage,
  head: () => ({ meta: [{ title: "Team — CaptureCat" }] }),
});

function TeamPage() {
  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-bold tracking-tight">Team</h1>
        <p className="text-muted-foreground">
          Shared library, members, and single sign-on.
        </p>
      </div>
      <TeamCards />
    </div>
  );
}
