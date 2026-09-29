import { createFileRoute } from "@tanstack/react-router";

import { CustomDomainsCard } from "@/components/dashboard/custom-domains-card";
import { ProfileCard } from "@/components/dashboard/profile-card";
import { PageHeader, Sections } from "@/components/dashboard/studio";

export const Route = createFileRoute("/app/settings")({
  component: SettingsPage,
  head: () => ({ meta: [{ title: "Settings — CaptureCat" }] }),
});

function SettingsPage() {
  return (
    <div className="space-y-6">
      <PageHeader
        eyebrow="Account"
        title="Settings"
        description="Your public profile and the domains your share links live on."
      />
      <Sections className="max-w-3xl">
        <ProfileCard />
        <CustomDomainsCard />
      </Sections>
    </div>
  );
}
