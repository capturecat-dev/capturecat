import type { Faq } from "../pseo-content";

/**
 * The docs content model (/docs). Pages are typed data, not MDX: the same
 * record renders the HTML page, the Markdown twin (/docs/….md), the sitemap
 * entry, the llms.txt line and the JSON-LD, so none of them can drift.
 *
 * Text fields accept a small inline-Markdown subset, rendered by
 * components/docs/DocBlocks.tsx and passed through verbatim to the twin:
 *
 *   **bold**   `code`   [label](/docs/…)   [label](https://…)
 *
 * Nothing else is interpreted — no HTML, no headings inside text.
 */

export type DocBlock =
  /** A paragraph. */
  | { type: "p"; text: string }
  /** A section heading. `id` becomes the anchor (default: slugified text). */
  | { type: "h2"; text: string; id?: string }
  | { type: "h3"; text: string; id?: string }
  /** Bulleted or numbered list. */
  | { type: "list"; items: string[]; ordered?: boolean }
  /** Numbered procedure. Becomes a HowTo in JSON-LD when it is the page's
   *  first `steps` block. */
  | { type: "steps"; steps: Array<{ title: string; text: string }> }
  /** Code or config. `lang` is a label only (json, bash, text…). */
  | { type: "code"; lang?: string; code: string; caption?: string }
  /** An aside. `pro`/`business` mark plan-gated behaviour. */
  | { type: "callout"; tone: "note" | "tip" | "warning" | "pro"; title?: string; text: string }
  /** A table; cells take inline Markdown. */
  | { type: "table"; head: string[]; rows: string[][] }
  /** Keyboard shortcuts, e.g. [["⌘⇧2", "Start or stop recording"]]. */
  | { type: "shortcuts"; rows: Array<[keys: string, action: string]> };

export type DocPlatform = "mac" | "web";

export interface DocPage {
  /** Path under /docs, e.g. "custom-storage/aws-s3". Lowercase, hyphens, "/". */
  slug: string;
  /** H1 and sidebar label source. */
  title: string;
  /** Shorter sidebar label when the title is long. */
  navTitle?: string;
  /** Full <title> when "title | CaptureCat Docs" is wrong or too long. */
  seoTitle?: string;
  /** Meta description, under 160 characters, written for the search result. */
  description: string;
  /** One or two quotable sentences under the H1 (the "short answer"). */
  summary: string;
  /** Which apps the page applies to. Omit for account/API pages. */
  platforms?: DocPlatform[];
  /** The plan the feature needs. Omit when it is free. */
  plan?: "pro" | "business";
  blocks: DocBlock[];
  faqs?: Faq[];
  /** Other doc slugs worth reading next. */
  related?: string[];
  /** YYYY-MM-DD of the last content check against the code. */
  lastModified: string;
}

export interface DocSection {
  /** URL segment of the section's pages, e.g. "custom-storage". */
  id: string;
  title: string;
  /** One line for the docs home. */
  description: string;
  pages: DocPage[];
}
