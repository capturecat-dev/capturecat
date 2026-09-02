import { createFileRoute } from "@tanstack/react-router";

import { CustomDomainsCard } from "@/components/dashboard/custom-domains-card";
import { ProfileCard } from "@/components/dashboard/profile-card";

export const Route = createFileRoute("/app/settings")({
  component: SettingsPage,
  head: () => ({ meta: [{ title: "Settings — CaptureCat" }] }),
});

function SettingsPage() {
  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-bold tracking-tight">Settings</h1>
        <p className="text-muted-foreground">
          Account settings and preferences.
        </p>
      </div>
      <ProfileCard />
      <CustomDomainsCard />
    </div>
  );
}
