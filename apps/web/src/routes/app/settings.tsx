import { createFileRoute } from "@tanstack/react-router";

import { SettingsPageBody } from "@/components/dashboard/account-pages";

export const Route = createFileRoute("/app/settings")({
  component: SettingsPageBody,
  head: () => ({ meta: [{ title: "Settings — CaptureCat" }] }),
});
