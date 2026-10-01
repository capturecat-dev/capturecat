/**
 * The bodies of the account pages (/app/settings, /app/billing, /app/team).
 * The route files only declare the route; the DEV lab renders these same
 * bodies without a session, so its screenshots are the real pages.
 */
import { BillingStatus } from "@/components/dashboard/billing-status";
import { CustomDomainsCard } from "@/components/dashboard/custom-domains-card";
import { ProfileCard } from "@/components/dashboard/profile-card";
import { PageHeader, Sections } from "@/components/dashboard/studio";
import { TeamCards } from "@/components/dashboard/team-cards";

export function SettingsPageBody() {
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

export function BillingPageBody({ success }: { success: boolean }) {
  return (
    <div className="space-y-6">
      <PageHeader
        eyebrow="Account"
        title="Billing"
        description="Your plan, what it includes, and where to change it."
      />
      <BillingStatus success={success} />
    </div>
  );
}

export function TeamPageBody() {
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
