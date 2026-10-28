import { createFileRoute } from "@tanstack/react-router";

import { ApprovalPage } from "@/components/dashboard/approval-page";

/** An agent's "ask me first" request (the approve_url an agent shows you). */
export const Route = createFileRoute("/app/approvals/$id")({
  component: ApprovalRoute,
  head: () => ({ meta: [{ title: "Approve agent request — CaptureCat" }] }),
});

function ApprovalRoute() {
  const { id } = Route.useParams();
  return <ApprovalPage id={id} />;
}
