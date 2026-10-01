import { createFileRoute } from "@tanstack/react-router";

import { TeamPageBody } from "@/components/dashboard/account-pages";

export const Route = createFileRoute("/app/team")({
  component: TeamPageBody,
  head: () => ({ meta: [{ title: "Team — CaptureCat" }] }),
});
