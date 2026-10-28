import { createFileRoute } from "@tanstack/react-router";
import { LegalLayout } from "@/components/marketing/LegalLayout";
import { ORGANIZATION_JSON_LD, jsonLd } from "@/lib/json-ld";
import { pageHead } from "@/lib/site-content";

/** How to reach CaptureCat. Mirrors the /contact Markdown twin in site-content.ts. */
export const Route = createFileRoute("/contact")({
  head: () => pageHead("/contact"),
  component: ContactPage,
});

const SECTIONS = [
  { id: "email", label: "Email" },
  { id: "privacy", label: "Privacy and data requests" },
  { id: "bugs", label: "Bugs and feature requests" },
  { id: "billing", label: "Billing" },
  { id: "developers", label: "Developers and agents" },
  { id: "business", label: "Business details" },
];

function ContactPage() {
  return (
    <LegalLayout title="Contact CaptureCat" updated="27 October 2026" sections={SECTIONS} eyebrow="Company">
      <script
        type="application/ld+json"
        dangerouslySetInnerHTML={{ __html: jsonLd({ "@context": "https://schema.org", ...ORGANIZATION_JSON_LD }) }}
      />
      <section className="space-y-3">
        <h2 id="email">Email</h2>
        <p>
          <a href="mailto:contact@capturecat.so">contact@capturecat.so</a> is one inbox for everything: help with the
          app, billing and subscriptions, account and data questions, and press. A person reads it.
        </p>
      </section>

      <section className="space-y-3">
        <h2 id="privacy">Privacy and data requests</h2>
        <p>
          To access, correct, export or delete your data, email{" "}
          <a href="mailto:contact@capturecat.so">contact@capturecat.so</a> from the address on your account. The{" "}
          <a href="/privacy">privacy policy</a> explains your rights. You can also complain to the UK Information
          Commissioner&apos;s Office at{" "}
          <a href="https://ico.org.uk" rel="nofollow noopener" target="_blank">
            ico.org.uk
          </a>
          .
        </p>
      </section>

      <section className="space-y-3">
        <h2 id="bugs">Bugs and feature requests</h2>
        <p>
          Open an issue on{" "}
          <a href="https://github.com/capturecat-dev/capturecat/issues" rel="noopener" target="_blank">
            GitHub
          </a>
          . The source is there too.
        </p>
      </section>

      <section className="space-y-3">
        <h2 id="billing">Billing</h2>
        <p>
          Manage or cancel a Pro subscription from your <a href="https://app.capturecat.so/billing">billing page</a>.
          For anything it cannot do, email us.
        </p>
      </section>

      <section className="space-y-3">
        <h2 id="developers">Developers and agents</h2>
        <p>
          Read the <a href="/docs">documentation</a>, the <a href="/docs/api">API reference</a> and its{" "}
          <a href="/openapi.json">OpenAPI description</a>, and <a href="/auth.md">how agents authenticate</a>. The MCP
          server is covered on <a href="/agents">Agents and MCP</a>.
        </p>
      </section>

      <section className="space-y-3">
        <h2 id="business">Business details</h2>
        <p>
          CaptureCat is operated by a sole trader based in the United Kingdom, trading as &ldquo;CaptureCat&rdquo;.
          Our full legal name and trading address are available to customers on request at the email above.
        </p>
      </section>
    </LegalLayout>
  );
}
