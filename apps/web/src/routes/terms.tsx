import { createFileRoute } from "@tanstack/react-router";
import Navbar from "@/components/marketing/Navbar";
import Footer from "@/components/marketing/Footer";
import { markdownAlternateLinks } from "@/lib/site-content";

export const Route = createFileRoute("/terms")({
  head: () => ({
    meta: [
      { title: "Terms of Service | CaptureCat" },
      {
        name: "description",
        content: "The terms that govern your use of the CaptureCat app, share links, and Pro subscription, under the laws of England and Wales.",
      },
    ],
    links: markdownAlternateLinks("/terms"),
  }),
  component: TermsPage,
});

const EFFECTIVE = "5 August 2026";

function TermsPage() {
  return (
    <main className="min-h-screen bg-background flex flex-col">
      <Navbar />
      <article className="mx-auto w-full max-w-3xl flex-1 px-6 py-20">
        <h1 className="text-4xl font-semibold tracking-[-0.03em]">
          Terms of Service
        </h1>
        <p className="mt-3 text-sm text-muted-foreground">
          Last updated: {EFFECTIVE}
        </p>

        <div className="mt-10 space-y-8 text-[15px] leading-relaxed text-muted-foreground [&_h2]:text-xl [&_h2]:font-medium [&_h2]:text-foreground [&_h2]:tracking-[-0.01em] [&_a]:text-foreground [&_a]:underline [&_ul]:list-disc [&_ul]:pl-6 [&_ul]:space-y-1.5">
          <section className="space-y-3">
            <h2>1. Who we are and these terms</h2>
            <p>
              CaptureCat is a service operated by a sole trader based in the
              United Kingdom, trading as &ldquo;CaptureCat&rdquo;
              (&ldquo;we&rdquo;, &ldquo;us&rdquo;, &ldquo;our&rdquo;). You can
              reach us at{" "}
              <a href="mailto:contact@capturecat.so">contact@capturecat.so</a>,
              and our full legal name and trading address are available to
              customers on request at that address.
            </p>
            <p>
              These terms form a legally binding agreement between you and us
              governing your use of the CaptureCat macOS app, the websites at
              capturecat.so and app.capturecat.so, and related services (together,
              the &ldquo;Service&rdquo;). By using the Service you accept these
              terms. If you do not accept them, please do not use the Service.
            </p>
          </section>

          <section className="space-y-3">
            <h2>2. Your account</h2>
            <p>
              You sign in using Google or Apple. You are responsible for keeping
              access to that account secure and for activity that takes place
              under it. You must be at least 13 years old to use the Service.
            </p>
          </section>

          <section className="space-y-3">
            <h2>3. Licence to use the app</h2>
            <p>
              We grant you a personal, non-exclusive, non-transferable licence to
              install and use the CaptureCat app on Macs you own or control, for
              your own use. You must not copy, resell, reverse engineer, or
              redistribute the app except to the extent the law permits.
            </p>
          </section>

          <section className="space-y-3">
            <h2>4. Your content</h2>
            <p>
              You keep ownership of every recording you make and every video or
              image you upload (&ldquo;Your Content&rdquo;). You grant us only the
              limited licence needed to host, process, and deliver Your Content so
              the Service works, for example, so a share link plays for the
              people you send it to. That licence ends when you delete the content
              or close your account, subject to short technical delays and
              backups.
            </p>
            <p>You agree not to upload content that:</p>
            <ul>
              <li>you do not have the right to share;</li>
              <li>
                is unlawful, defamatory, infringing, or breaches anyone&apos;s
                privacy; or
              </li>
              <li>contains malware or is intended to harm others.</li>
            </ul>
            <p>
              We may remove content and suspend or terminate accounts that breach
              these terms.
            </p>
          </section>

          <section className="space-y-3">
            <h2>5. Subscriptions and payment</h2>
            <p>
              CaptureCat is free to use with an optional paid plan
              (&ldquo;Pro&rdquo;). Pro is billed through Stripe on a monthly or
              annual basis and renews automatically at the then-current price
              until cancelled. Prices are shown at checkout and include VAT where
              applicable. You can cancel at any time from your billing page;
              cancellation stops future renewals and your access continues until
              the end of the period you have paid for.
            </p>
          </section>

          <section className="space-y-3">
            <h2>6. Your right to cancel and refunds</h2>
            <p>
              Because Pro is digital content and services supplied online, you
              have a legal right under the Consumer Contracts Regulations 2013 to
              cancel within 14 days of subscribing. However, by starting to use
              paid features during that period you ask us to begin supply
              immediately and acknowledge that you lose the 14-day right to cancel
              once supply has begun, except to the extent the paid features have
              not yet been provided.
            </p>
            <p>
              Nothing in these terms affects your statutory rights under the
              Consumer Rights Act 2015, including the right to a service carried
              out with reasonable care and skill and to digital content that is of
              satisfactory quality, fit for purpose, and as described. If
              something is faulty, contact us and we will put it right or provide
              a remedy the law requires.
            </p>
          </section>

          <section className="space-y-3">
            <h2>7. Shared videos and analytics</h2>
            <p>
              When you make a video public and share its link, anyone with the
              link can view it until you make it private or delete it. We provide
              you with aggregate analytics about how your shared videos are viewed
              (see our{" "}
              <a href="/privacy">Privacy Policy</a>). You are responsible for
              ensuring you have the right to share what you upload.
            </p>
          </section>

          <section className="space-y-3">
            <h2>8. Availability</h2>
            <p>
              We work to keep the Service available and your share links working,
              but we provide the online parts of the Service on a reasonable-efforts
              basis and cannot guarantee uninterrupted access. Your exported video
              files are saved locally and do not depend on us. We recommend keeping
              your own copies of anything important.
            </p>
          </section>

          <section className="space-y-3">
            <h2>9. Our liability</h2>
            <p>
              We do not exclude or limit our liability where it would be unlawful
              to do so. This includes liability for death or personal injury
              caused by our negligence, for fraud, and for your statutory rights
              as a consumer. Subject to that, we are not liable for loss that is
              not reasonably foreseeable, for business losses, or for loss of data
              you could have avoided by keeping your own backups. Where we are
              liable, our total liability to you in any 12-month period is limited
              to the amount you paid us for the Service in that period.
            </p>
          </section>

          <section className="space-y-3">
            <h2>10. Suspension and termination</h2>
            <p>
              You may stop using the Service and close your account at any time.
              We may suspend or end your access if you materially breach these
              terms or use the Service unlawfully. On termination, the licences
              granted here end, though clauses that by their nature should survive
              (such as those on liability) will continue.
            </p>
          </section>

          <section className="space-y-3">
            <h2>11. Changes to these terms</h2>
            <p>
              We may update these terms from time to time. If we make material
              changes we will update the date above and, where appropriate, notify
              you. Continuing to use the Service after changes take effect means
              you accept the updated terms.
            </p>
          </section>

          <section className="space-y-3">
            <h2>12. Governing law</h2>
            <p>
              These terms are governed by the laws of England and Wales, and
              disputes are subject to the non-exclusive jurisdiction of the courts
              of England and Wales. If you are a consumer resident elsewhere in
              the UK, you may bring proceedings in your local courts and benefit
              from any mandatory protections of your home nation&apos;s law.
            </p>
          </section>

          <section className="space-y-3">
            <h2>13. Contact</h2>
            <p>
              Questions about these terms? Email{" "}
              <a href="mailto:contact@capturecat.so">contact@capturecat.so</a>.
            </p>
          </section>
        </div>
      </article>
      <Footer />
    </main>
  );
}
