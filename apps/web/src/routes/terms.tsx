import { createFileRoute } from "@tanstack/react-router";
import { LegalLayout } from "@/components/marketing/LegalLayout";
import { pageHead } from "@/lib/site-content";

export const Route = createFileRoute("/terms")({
  head: () => pageHead("/terms"),
  component: TermsPage,
});

const SECTIONS = [
  {
    id: "s1-who-we-are-and-these-terms",
    label: "1. Who we are and these terms",
  },
  { id: "s2-your-account", label: "2. Your account" },
  { id: "s3-licence-to-use-the-app", label: "3. Licence to use the app" },
  {
    id: "s4-personal-and-commercial-use",
    label: "4. Personal and commercial use",
  },
  { id: "s5-plans-and-fees", label: "5. Plans and fees" },
  {
    id: "s6-your-right-to-cancel-and-refunds",
    label: "6. Your right to cancel and refunds",
  },
  { id: "s7-your-content", label: "7. Your content" },
  {
    id: "s8-shared-videos-and-analytics",
    label: "8. Shared videos and analytics",
  },
  { id: "s9-availability", label: "9. Availability" },
  { id: "s10-our-liability", label: "10. Our liability" },
  {
    id: "s11-suspension-and-termination",
    label: "11. Suspension and termination",
  },
  { id: "s12-changes-to-these-terms", label: "12. Changes to these terms" },
  { id: "s13-governing-law", label: "13. Governing law" },
  { id: "s14-contact", label: "14. Contact" },
];

const EFFECTIVE = "29 October 2026";

function TermsPage() {
  return (
    <LegalLayout
      title="Terms of Service"
      updated={EFFECTIVE}
      sections={SECTIONS}
    >
      <section className="space-y-3">
        <h2 id="s1-who-we-are-and-these-terms">
          1. Who we are and these terms
        </h2>
        <p>
          CaptureCat is a service operated by a sole trader based in the United
          Kingdom, trading as &ldquo;CaptureCat&rdquo; (&ldquo;we&rdquo;,
          &ldquo;us&rdquo;, &ldquo;our&rdquo;). You can reach us at{" "}
          <a href="mailto:contact@capturecat.so">contact@capturecat.so</a>, and
          our full legal name and trading address are available to customers on
          request at that address.
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
        <h2 id="s2-your-account">2. Your account</h2>
        <p>
          You do not need an account to record or export with the CaptureCat
          Mac app. To share videos, use the web app, or subscribe to Pro, you
          sign in using Google or Apple. You are responsible for keeping access
          to that account secure and for activity that takes place under it.
          You must be at least 13 years old to use the Service.
        </p>
      </section>

      <section className="space-y-3">
        <h2 id="s3-licence-to-use-the-app">3. Licence to use the app</h2>
        <p>
          CaptureCat&apos;s source code is published under the GNU Affero
          General Public License, version 3 (&ldquo;AGPL-3.0&rdquo;). The
          AGPL-3.0 governs the source code, and nothing in these terms limits
          the rights it gives you. These terms govern the official builds of
          CaptureCat that we publish, such as the Mac app downloaded from
          capturecat.so, and the Service we operate.
        </p>
        <p>
          We grant you a non-exclusive, non-transferable licence to install and
          use the official builds on Macs you own or control, for personal use
          on the Free plan or for commercial use with an active Pro
          subscription, as section 4 explains. You must not resell the Service
          or let other people use your account.
        </p>
      </section>

      <section className="space-y-3">
        <h2 id="s4-personal-and-commercial-use">
          4. Personal and commercial use
        </h2>
        <p>
          The Free plan is for personal use only. Commercial use needs an
          active Pro subscription.
        </p>
        <p>
          &ldquo;Commercial use&rdquo; means any use of CaptureCat to record or
          edit content that is used in revenue-generating activities. That
          includes:
        </p>
        <ul>
          <li>client work;</li>
          <li>courses;</li>
          <li>marketing;</li>
          <li>content that promotes your employer&apos;s product or service; and</li>
          <li>communication between members of a company or team.</li>
        </ul>
        <p>
          Personal projects, learning, and hobby videos are personal use and
          are fine on Free.
        </p>
        <p>
          This is a term of your licence, not a technical lock: the app does
          not check what you record, so it is up to you to subscribe to Pro
          when your use is commercial. If you are not sure which applies to
          you, email{" "}
          <a href="mailto:contact@capturecat.so">contact@capturecat.so</a>.
        </p>
      </section>

      <section className="space-y-3">
        <h2 id="s5-plans-and-fees">5. Plans and fees</h2>
        <p>
          <strong>Free</strong> costs nothing. It is for personal use, and each
          recording stops at 5 minutes. It includes a small cloud allowance,
          currently 2 GB of storage in total, share links for videos up to 5
          minutes, and 10 new shares a day. Free does not include comments,
          viewer analytics, AI summaries, teams, custom domains, web page
          capture by URL, or screenshot uploads.
        </p>
        <p>
          <strong>Pro</strong> is a paid subscription. It covers commercial
          use, has no recording length limit, and adds the hosted features and
          allowances shown on our{" "}
          <a href="/pricing">pricing page</a>. Pro is billed through Stripe
          monthly or yearly and renews automatically at the then-current price
          until cancelled. Prices are shown on the pricing page and at checkout
          and include VAT where applicable. To use Pro in the Mac app, sign in
          to it with the account that holds the subscription. References to
          Pro in these terms include any other paid plan we offer.
        </p>
        <p>
          You can cancel at any time from your billing page. Cancelling stops
          future renewals, and your access continues until the end of the
          period you have paid for. Your account then moves to Free. Your share
          links keep playing while your stored videos fit within Free&apos;s
          storage allowance; past that, they pause until you free up space or
          subscribe again.
        </p>
        <p>
          The pricing page shows each plan&apos;s current features and
          allowances, which may change over time.
        </p>
      </section>

      <section className="space-y-3">
        <h2 id="s6-your-right-to-cancel-and-refunds">
          6. Your right to cancel and refunds
        </h2>
        <p>
          Because Pro is digital content and services supplied online, you have
          a legal right under the Consumer Contracts Regulations 2013 to cancel
          within 14 days of subscribing. However, by starting to use paid
          features during that period you ask us to begin supply immediately and
          acknowledge that you lose the 14-day right to cancel once supply has
          begun, except to the extent the paid features have not yet been
          provided.
        </p>
        <p>
          Nothing in these terms affects your statutory rights under the
          Consumer Rights Act 2015, including the right to a service carried out
          with reasonable care and skill and to digital content that is of
          satisfactory quality, fit for purpose, and as described. If something
          is faulty, contact us and we will put it right or provide a remedy the
          law requires.
        </p>
      </section>

      <section className="space-y-3">
        <h2 id="s7-your-content">7. Your content</h2>
        <p>
          You keep ownership of every recording you make and every video or
          image you upload (&ldquo;Your Content&rdquo;). You grant us only the
          limited licence needed to host, process, and deliver Your Content so
          the Service works, for example, so a share link plays for the people
          you send it to. That licence ends when you delete the content or close
          your account, subject to short technical delays and backups.
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
        <h2 id="s8-shared-videos-and-analytics">
          8. Shared videos and analytics
        </h2>
        <p>
          When you make a video public and share its link, anyone with the link
          can view it until you make it private or delete it, or until it is
          paused as section 5 describes. On plans that include them, we
          provide you with aggregate analytics about how your shared videos
          are viewed (see our <a href="/privacy">Privacy Policy</a>). You are
          responsible for ensuring you have the right to share what you
          upload.
        </p>
      </section>

      <section className="space-y-3">
        <h2 id="s9-availability">9. Availability</h2>
        <p>
          We work to keep the Service available and your share links working,
          but we provide the online parts of the Service on a reasonable-efforts
          basis and cannot guarantee uninterrupted access. Your exported video
          files are saved locally and do not depend on us. We recommend keeping
          your own copies of anything important.
        </p>
      </section>

      <section className="space-y-3">
        <h2 id="s10-our-liability">10. Our liability</h2>
        <p>
          We do not exclude or limit our liability where it would be unlawful to
          do so. This includes liability for death or personal injury caused by
          our negligence, for fraud, and for your statutory rights as a
          consumer. Subject to that, we are not liable for loss that is not
          reasonably foreseeable, for business losses, or for loss of data you
          could have avoided by keeping your own backups. Where we are liable,
          our total liability to you in any 12-month period is limited to the
          amount you paid us for the Service in that period.
        </p>
      </section>

      <section className="space-y-3">
        <h2 id="s11-suspension-and-termination">
          11. Suspension and termination
        </h2>
        <p>
          You may stop using the Service and close your account at any time. We
          may suspend or end your access if you materially breach these terms or
          use the Service unlawfully. On termination, the licences granted here
          end, though clauses that by their nature should survive (such as those
          on liability) will continue.
        </p>
      </section>

      <section className="space-y-3">
        <h2 id="s12-changes-to-these-terms">12. Changes to these terms</h2>
        <p>
          We may update these terms from time to time. If we make material
          changes we will update the date above and, where appropriate, notify
          you. Continuing to use the Service after changes take effect means you
          accept the updated terms.
        </p>
      </section>

      <section className="space-y-3">
        <h2 id="s13-governing-law">13. Governing law</h2>
        <p>
          These terms are governed by the laws of England and Wales, and
          disputes are subject to the non-exclusive jurisdiction of the courts
          of England and Wales. If you are a consumer resident elsewhere in the
          UK, you may bring proceedings in your local courts and benefit from
          any mandatory protections of your home nation&apos;s law.
        </p>
      </section>

      <section className="space-y-3">
        <h2 id="s14-contact">14. Contact</h2>
        <p>
          Questions about these terms? Email{" "}
          <a href="mailto:contact@capturecat.so">contact@capturecat.so</a>.
        </p>
      </section>
    </LegalLayout>
  );
}
