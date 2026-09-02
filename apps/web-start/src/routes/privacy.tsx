import { createFileRoute } from "@tanstack/react-router";
import Navbar from "@/components/landing/Navbar";
import Footer from "@/components/landing/Footer";
import { markdownAlternateLinks } from "@/lib/site-content";

export const Route = createFileRoute("/privacy")({
  head: () => ({
    meta: [
      { title: "Privacy Policy | CaptureCat" },
      {
        name: "description",
        content: "How CaptureCat collects, uses, and protects your personal data under UK GDPR and the Data Protection Act 2018, and the rights you have over it.",
      },
    ],
    links: markdownAlternateLinks("/privacy"),
  }),
  component: PrivacyPage,
});

const EFFECTIVE = "5 August 2026";

function PrivacyPage() {
  return (
    <main className="min-h-screen bg-background flex flex-col">
      <Navbar />
      <article className="mx-auto w-full max-w-3xl flex-1 px-6 py-20">
        <h1 className="text-4xl font-semibold tracking-[-0.03em]">Privacy Policy</h1>
        <p className="mt-3 text-sm text-muted-foreground">
          Last updated: {EFFECTIVE}
        </p>

        <div className="mt-10 space-y-8 text-[15px] leading-relaxed text-muted-foreground [&_h2]:text-xl [&_h2]:font-medium [&_h2]:text-foreground [&_h2]:tracking-[-0.01em] [&_h3]:text-base [&_h3]:font-medium [&_h3]:text-foreground [&_a]:text-foreground [&_a]:underline [&_ul]:list-disc [&_ul]:pl-6 [&_ul]:space-y-1.5">
          <section className="space-y-3">
            <p>
              This policy explains how CaptureCat handles your personal data, the
              lawful bases we rely on, and the rights you have. It is written to
              comply with the UK General Data Protection Regulation (UK GDPR) and
              the Data Protection Act 2018.
            </p>
          </section>

          <section className="space-y-3">
            <h2>1. Who we are</h2>
            <p>
              CaptureCat is a service operated by a sole trader based in the
              United Kingdom, trading as &ldquo;CaptureCat&rdquo;
              (&ldquo;we&rdquo;, &ldquo;us&rdquo;, &ldquo;our&rdquo;). We are the
              data controller for the personal data described in this policy.
            </p>
            <ul>
              <li>
                Contact:{" "}
                <a href="mailto:contact@capturecat.so">contact@capturecat.so</a>
              </li>
              <li>
                Our full legal name and trading address are available to
                customers on request — just email the address above.
              </li>
            </ul>
          </section>

          <section className="space-y-3">
            <h2>2. The data we collect</h2>
            <h3>Account data</h3>
            <p>
              When you sign in with Google or Apple, we receive your name, email
              address, and profile picture. We never receive your Google or Apple
              password.
            </p>
            <h3>Billing data</h3>
            <p>
              Subscriptions are handled by Stripe. Stripe processes your card
              details and billing information as a separate controller; we
              receive only your subscription status and limited billing metadata
              (for example, the last four digits of your card and your country).
              We never see or store full card numbers.
            </p>
            <h3>Content you upload</h3>
            <p>
              Recordings and images you choose to upload for sharing are stored
              on our infrastructure so that share links work. Recordings that you
              do not upload never leave your Mac.
            </p>
            <h3>Viewer analytics</h3>
            <p>
              When someone views a shared video, we collect aggregate viewing
              data for the video&apos;s owner: view counts, how far into the
              video each viewer watched, player interactions (play, pause, seek,
              clicks), approximate country, referring page, and device type.
              Viewers are identified by a random, per-tab identifier held only in
              memory — not a persistent tracking cookie.
            </p>
            <h3>Technical data</h3>
            <p>
              Our servers automatically log IP addresses and request metadata for
              security, rate limiting, and abuse prevention.
            </p>
          </section>

          <section className="space-y-3">
            <h2>3. How and why we use your data (lawful bases)</h2>
            <ul>
              <li>
                <span className="text-foreground">To provide the service</span>{" "}
                (create your account, store and serve your shared videos, show
                you analytics) — lawful basis: performance of a contract.
              </li>
              <li>
                <span className="text-foreground">To take payment</span> and
                manage your subscription — lawful basis: performance of a
                contract.
              </li>
              <li>
                <span className="text-foreground">To keep the service secure</span>{" "}
                (rate limiting, fraud and abuse prevention, logging) — lawful
                basis: our legitimate interests in protecting the service and its
                users.
              </li>
              <li>
                <span className="text-foreground">To meet legal obligations</span>{" "}
                (for example, tax and accounting records) — lawful basis: legal
                obligation.
              </li>
            </ul>
          </section>

          <section className="space-y-3">
            <h2>4. Who we share data with</h2>
            <p>
              We do not sell your personal data. We share it only with the
              service providers (processors) needed to run CaptureCat:
            </p>
            <ul>
              <li>
                <span className="text-foreground">Cloudflare</span> — hosting,
                content delivery, database, and video storage.
              </li>
              <li>
                <span className="text-foreground">Stripe</span> — payment
                processing and subscription management.
              </li>
              <li>
                <span className="text-foreground">Google and Apple</span> —
                authentication when you choose to sign in with them.
              </li>
            </ul>
            <p>
              Each provider is bound by contract to process data only on our
              instructions and to keep it secure. We may also disclose data where
              required by law.
            </p>
          </section>

          <section className="space-y-3">
            <h2>5. International transfers</h2>
            <p>
              Some of our providers process data outside the United Kingdom. Where
              they do, the transfer is protected by appropriate safeguards — the
              UK International Data Transfer Agreement, the UK Addendum to the EU
              Standard Contractual Clauses, or an adequacy decision — so your data
              receives an equivalent level of protection.
            </p>
          </section>

          <section className="space-y-3">
            <h2>6. How long we keep it</h2>
            <p>
              We keep account data for as long as you have an account. If you
              delete a video it is removed from storage; if you close your
              account we delete your personal data within 30 days, except where we
              must retain limited records for legal reasons (for example, tax
              records, which are kept for six years). Aggregate analytics that no
              longer identify an individual may be retained.
            </p>
          </section>

          <section className="space-y-3">
            <h2>7. Your rights</h2>
            <p>Under UK data protection law you have the right to:</p>
            <ul>
              <li>access a copy of your personal data;</li>
              <li>have inaccurate data corrected;</li>
              <li>have your data erased;</li>
              <li>restrict or object to how we process your data;</li>
              <li>data portability; and</li>
              <li>withdraw consent where we rely on it.</li>
            </ul>
            <p>
              To exercise any of these, email{" "}
              <a href="mailto:contact@capturecat.so">contact@capturecat.so</a>. You
              also have the right to complain to the Information Commissioner&apos;s
              Office (ICO) at{" "}
              <a href="https://ico.org.uk" rel="nofollow noopener" target="_blank">
                ico.org.uk
              </a>
              , though we&apos;d appreciate the chance to help first.
            </p>
          </section>

          <section className="space-y-3">
            <h2>8. Cookies</h2>
            <p>
              We use a single essential cookie to keep you signed in. We do not
              use advertising or third-party tracking cookies. Viewer analytics on
              shared videos rely on a random per-tab identifier, not a cookie.
            </p>
          </section>

          <section className="space-y-3">
            <h2>9. Children</h2>
            <p>
              CaptureCat is not directed at children under 13, and we do not
              knowingly collect their personal data.
            </p>
          </section>

          <section className="space-y-3">
            <h2>10. Changes to this policy</h2>
            <p>
              We may update this policy from time to time. If we make material
              changes we will update the date above and, where appropriate, notify
              you.
            </p>
          </section>

          <section className="space-y-3">
            <h2>11. Contact</h2>
            <p>
              Questions about this policy or your data? Email{" "}
              <a href="mailto:contact@capturecat.so">contact@capturecat.so</a>.
            </p>
          </section>
        </div>
      </article>
      <Footer />
    </main>
  );
}
