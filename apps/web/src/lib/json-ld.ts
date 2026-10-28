/**
 * Serialize an object for an inline `<script type="application/ld+json">`.
 *
 * Script bodies are emitted raw (TanStack renders `children` via
 * dangerouslySetInnerHTML), and JSON.stringify does not escape `<` — so a
 * value like an upload's fileName containing `</script><script>…` would break
 * out of the block and execute on this origin. Escaping `<` as `\\u003c`
 * keeps the output valid JSON while making `</script>` impossible; U+2028 and
 * U+2029 are escaped because they are line terminators in JS but not in JSON.
 */
export function jsonLd(value: unknown): string {
  return JSON.stringify(value)
    .replace(/</g, "\\u003c")
    .replace(/\u2028/g, "\\u2028")
    .replace(/\u2029/g, "\\u2029");
}

/**
 * The business behind the site, for agents verifying who they are dealing
 * with. Truthful to the privacy policy's "Who we are": a UK sole trader whose
 * full legal name and street address are given on request, so the address is
 * country-level only. Publishing the street address is a decision for the
 * owner, not this file.
 */
export const ORGANIZATION_JSON_LD = {
  "@type": "Organization",
  "@id": "https://capturecat.so/#organization",
  name: "CaptureCat",
  url: "https://capturecat.so",
  logo: "https://capturecat.so/icon.png",
  email: "contact@capturecat.so",
  description:
    "CaptureCat makes an open-source screen recorder for Mac that edits recordings automatically, with share links and an MCP server for AI agents.",
  sameAs: ["https://github.com/capturecat-dev/capturecat"],
  address: { "@type": "PostalAddress", addressCountry: "GB" },
  contactPoint: [
    {
      "@type": "ContactPoint",
      contactType: "customer support",
      email: "contact@capturecat.so",
      url: "https://capturecat.so/contact",
      availableLanguage: ["English"],
    },
  ],
} as const;
