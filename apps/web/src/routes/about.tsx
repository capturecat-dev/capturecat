import { createFileRoute } from "@tanstack/react-router";
import { LegalLayout } from "@/components/marketing/LegalLayout";
import { ORGANIZATION_JSON_LD, jsonLd } from "@/lib/json-ld";
import { pageHead } from "@/lib/site-content";

/** Who makes CaptureCat. Mirrors the /about Markdown twin in site-content.ts. */
export const Route = createFileRoute("/about")({
  head: () => pageHead("/about"),
  component: AboutPage,
});

const SECTIONS = [
  { id: "what-it-is", label: "What CaptureCat is" },
  { id: "open-source", label: "Free and open source" },
  { id: "private", label: "Private by default" },
  { id: "agents", label: "Built for agents too" },
  { id: "who-we-are", label: "Who we are" },
  { id: "contact", label: "Contact" },
];

function AboutPage() {
  return (
    <LegalLayout title="About CaptureCat" updated="27 October 2026" sections={SECTIONS} eyebrow="Company">
      <script
        type="application/ld+json"
        dangerouslySetInnerHTML={{ __html: jsonLd({ "@context": "https://schema.org", ...ORGANIZATION_JSON_LD }) }}
      />
      <section className="space-y-3">
        <h2 id="what-it-is">What CaptureCat is</h2>
        <p>
          CaptureCat is a screen recorder for Mac that edits itself. It records a display, a window, an area, an
          iPhone or iPad, or a web page by URL, and captures your clicks, cursor and keystrokes as data. Then it does
          the editing a screen video usually needs: zooms where you worked, a smoothed cursor with click ripples,
          on-device captions, blur for anything private, and a framed, styled export.
        </p>
        <p>
          The preview and the exported file are rendered from the same frame, so what you see is what you get. It
          also runs in the browser on Windows, Linux and ChromeOS.
        </p>
      </section>

      <section className="space-y-3">
        <h2 id="open-source">Free and open source</h2>
        <p>
          Recording, the editor, every effect, and export are free with no time limit and no resolution cap. Pro adds
          share links with comments and viewer analytics. Every line is on{" "}
          <a href="https://github.com/capturecat-dev/capturecat" rel="noopener" target="_blank">
            GitHub
          </a>{" "}
          under the AGPL-3.0. The Mac app is native Swift, with no Electron.
        </p>
      </section>

      <section className="space-y-3">
        <h2 id="private">Private by default</h2>
        <p>
          Recordings are ordinary project folders on your Mac and never leave it unless you choose to share them.
          Captions are transcribed on device.
        </p>
      </section>

      <section className="space-y-3">
        <h2 id="agents">Built for agents too</h2>
        <p>
          The app ships a Model Context Protocol server, so Claude, Codex, Cursor, Copilot and Windsurf can record,
          edit and export for you (see <a href="/agents">Agents and MCP</a>). Developers can use the{" "}
          <a href="/docs/api">CaptureCat API</a>.
        </p>
      </section>

      <section className="space-y-3">
        <h2 id="who-we-are">Who we are</h2>
        <p>
          CaptureCat is operated by a sole trader based in the United Kingdom, trading as &ldquo;CaptureCat&rdquo;.
          Our full legal name and trading address are available to customers on request.
        </p>
      </section>

      <section className="space-y-3">
        <h2 id="contact">Contact</h2>
        <p>
          Email <a href="mailto:contact@capturecat.so">contact@capturecat.so</a>, or see the{" "}
          <a href="/contact">contact page</a>.
        </p>
      </section>
    </LegalLayout>
  );
}
