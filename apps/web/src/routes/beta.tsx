import { createFileRoute } from "@tanstack/react-router";
import { Sparkles } from "lucide-react";

import { BetaForm } from "@/components/marketing/BetaForm";
import { AirPage, AirPageHero } from "@/components/marketing/airy/Page";
import airyCss from "@/styles/airy.css?url";

// Deliberately unlinked and non-indexed: the URL is shared directly, not
// discovered. Kept out of SITE_PAGES too, so it has no Markdown twin.
export const Route = createFileRoute("/beta")({
  head: () => ({
    meta: [
      { title: "Join the Beta | CaptureCat" },
      {
        name: "description",
        content:
          "Get early access to CaptureCat. Drop your email to join the beta and we'll be in touch.",
      },
      { name: "robots", content: "noindex, nofollow" },
    ],
    links: [{ rel: "stylesheet", href: airyCss }],
  }),
  component: BetaPage,
});

function BetaPage() {
  return (
    <AirPage>
      <AirPageHero
        pill="Private beta"
        icon={<Sparkles className="h-3.5 w-3.5" strokeWidth={2} />}
        title="Get early access to CaptureCat."
        lede="Drop your email to join the beta. We’ll send an invite as soon as a spot opens up. No spam, ever."
        className="md:pb-28"
      >
        <div className="mt-12 flex w-full justify-center text-left">
          <BetaForm />
        </div>
      </AirPageHero>
    </AirPage>
  );
}
