import { createFileRoute } from "@tanstack/react-router";

import { Recorder } from "@/components/dashboard/recorder";

export const Route = createFileRoute("/app/record")({
  component: Recorder,
  head: () => ({ meta: [{ title: "Record — CaptureCat" }] }),
});
