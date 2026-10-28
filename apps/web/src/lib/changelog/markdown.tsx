/**
 * The changelog's Markdown renderer — the ONE renderer for an entry body,
 * used by the public pages (capturecat.so/changelog), the admin editor's live
 * preview (apps/admin imports this file by relative path) and the RSS feed's
 * HTML. Preview and public page cannot disagree because they run this code.
 *
 * SAFE BY CONSTRUCTION. The site has no general Markdown renderer (the docs
 * are typed blocks), so this is a deliberately small one:
 *
 *   - The source is parsed into a tree of plain data (MdBlock / MdInline).
 *     Text only ever becomes React text children (escaped by React) or goes
 *     through `escapeHtml` in the feed — never `dangerouslySetInnerHTML`, so
 *     `<script>`, `<img onerror>` and friends show up as literal text.
 *   - Links: only absolute http(s) URLs, re-serialized by `new URL()`.
 *     Anything else (`javascript:`, `data:`, relative paths) renders as its
 *     text with no anchor. Links off capturecat.so open in a new tab with
 *     rel="noopener noreferrer".
 *   - No images, no raw HTML, no tables.
 *
 * Supported: ATX headings (#…######), paragraphs, bullet and numbered lists
 * (nested by indenting), > quotes, fenced code blocks, --- rules, **bold**,
 * *italic* / _italic_, `inline code`, [links](https://…) and \-escapes.
 *
 * Pathological input stays linear-ish: nesting is capped, link and code-span
 * scans are bounded, and a failed search for an emphasis/code closer is
 * remembered so later openers don't rescan the rest of the line.
 *
 * No `@/` imports: this file is compiled by both apps/web and apps/admin.
 */
import { createElement, type ReactNode } from "react";

// ── tree ────────────────────────────────────────────────────────────────────

export type MdInline =
  | { type: "text"; text: string }
  | { type: "strong"; children: MdInline[] }
  | { type: "em"; children: MdInline[] }
  | { type: "code"; text: string }
  | { type: "link"; href: string; external: boolean; children: MdInline[] };

export type MdBlock =
  | { type: "heading"; level: number; children: MdInline[] }
  | { type: "paragraph"; children: MdInline[] }
  | { type: "list"; ordered: boolean; start: number; items: MdBlock[][] }
  | { type: "quote"; children: MdBlock[] }
  | { type: "code"; lang: string | null; text: string }
  | { type: "rule" };

const MAX_BLOCK_DEPTH = 6;
const MAX_INLINE_DEPTH = 8;
const MAX_LINK_TEXT = 1_000;
const MAX_LINK_URL = 2_048;

/** First-party hosts: links here stay in the tab. */
const SITE_HOSTS = new Set(["capturecat.so", "www.capturecat.so", "app.capturecat.so"]);

/** An absolute http(s) URL, normalised; anything else is not a link. */
export function safeHref(raw: string): { href: string; external: boolean } | null {
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    return null;
  }
  if (url.protocol !== "http:" && url.protocol !== "https:") return null;
  return { href: url.href, external: !SITE_HOSTS.has(url.hostname) };
}

// ── blocks ──────────────────────────────────────────────────────────────────

const HEADING_RE = /^ {0,3}(#{1,6})(?:[ \t]+(.*))?$/;
const RULE_RE = /^ {0,3}(?:(?:\*[ \t]*){3,}|(?:-[ \t]*){3,}|(?:_[ \t]*){3,})$/;
const QUOTE_RE = /^ {0,3}> ?(.*)$/;
const BULLET_RE = /^( {0,3})([-*+])([ \t]+)(.*)$/;
const ORDERED_RE = /^( {0,3})(\d{1,9})([.)])([ \t]+)(.*)$/;

/** An opening code fence: ``` or ~~~ (3+), then an info string whose first
 *  word is the language. A backtick fence's info string may not contain a
 *  backtick, so "```code```" on one line stays inline code. */
function fenceOpen(line: string): { marker: string; lang: string | null } | null {
  const m = /^ {0,3}(`{3,}|~{3,})(.*)$/.exec(line);
  if (!m || (m[1][0] === "`" && m[2].includes("`"))) return null;
  const lang = m[2].trim().split(/\s+/)[0];
  return { marker: m[1], lang: lang ? lang.slice(0, 20) : null };
}

const isBlank = (line: string) => line.trim() === "";
const indentOf = (line: string) => line.length - line.replace(/^ +/, "").length;

interface ListMarker {
  ordered: boolean;
  start: number;
  /** Columns before the item's text: indent + marker + spacing. */
  contentIndent: number;
  indent: number;
  text: string;
}

function listMarker(line: string): ListMarker | null {
  if (RULE_RE.test(line)) return null; // "- - -" is a rule, not a list
  const b = BULLET_RE.exec(line);
  if (b) {
    const spacing = Math.min(b[3].length, 4);
    return { ordered: false, start: 1, indent: b[1].length, contentIndent: b[1].length + 1 + spacing, text: b[4] };
  }
  const o = ORDERED_RE.exec(line);
  if (o) {
    const spacing = Math.min(o[4].length, 4);
    return {
      ordered: true,
      start: Number(o[2]),
      indent: o[1].length,
      contentIndent: o[1].length + o[2].length + 1 + spacing,
      text: o[5],
    };
  }
  return null;
}

/** Lines that begin a new block (and so end a paragraph). */
function startsBlock(line: string): boolean {
  if (fenceOpen(line) || HEADING_RE.test(line) || RULE_RE.test(line) || QUOTE_RE.test(line)) return true;
  const m = listMarker(line);
  // Only a list starting at 1 may interrupt a paragraph ("2024. was busy" stays text).
  return !!m && (!m.ordered || m.start === 1);
}

export function parseMarkdown(source: string): MdBlock[] {
  return parseBlocks(source.replace(/\r\n?/g, "\n").replace(/\t/g, "    ").split("\n"), 0);
}

function parseBlocks(lines: string[], depth: number): MdBlock[] {
  const blocks: MdBlock[] = [];
  let i = 0;
  while (i < lines.length) {
    const line = lines[i];
    if (isBlank(line)) {
      i++;
      continue;
    }

    const fence = fenceOpen(line);
    if (fence) {
      const closer = new RegExp(`^ {0,3}${fence.marker[0] === "`" ? "`" : "~"}{${fence.marker.length},}[ \\t]*$`);
      const body: string[] = [];
      i++;
      while (i < lines.length && !closer.test(lines[i])) body.push(lines[i++]);
      i++; // the closing fence (or past the end)
      blocks.push({ type: "code", lang: fence.lang, text: body.join("\n") });
      continue;
    }

    const heading = HEADING_RE.exec(line);
    if (heading) {
      const text = (heading[2] ?? "").replace(/[ \t]+#+[ \t]*$/, "").replace(/^#+[ \t]*$/, "").trim();
      blocks.push({ type: "heading", level: heading[1].length, children: parseInline(text) });
      i++;
      continue;
    }

    if (RULE_RE.test(line)) {
      blocks.push({ type: "rule" });
      i++;
      continue;
    }

    if (depth < MAX_BLOCK_DEPTH && QUOTE_RE.test(line)) {
      const inner: string[] = [];
      for (let m = QUOTE_RE.exec(line); m; m = i < lines.length ? QUOTE_RE.exec(lines[i]) : null) {
        inner.push(m[1]);
        i++;
      }
      blocks.push({ type: "quote", children: parseBlocks(inner, depth + 1) });
      continue;
    }

    const marker = depth < MAX_BLOCK_DEPTH ? listMarker(line) : null;
    if (marker) {
      const parsed = parseList(lines, i, marker, depth);
      blocks.push(parsed.list);
      i = parsed.next;
      continue;
    }

    const para: string[] = [line.trim()];
    i++;
    while (i < lines.length && !isBlank(lines[i]) && !startsBlock(lines[i])) para.push(lines[i++].trim());
    blocks.push({ type: "paragraph", children: parseInline(para.join("\n")) });
  }
  return blocks;
}

function parseList(lines: string[], from: number, first: ListMarker, depth: number) {
  const items: MdBlock[][] = [];
  let i = from;
  let marker: ListMarker | null = first;
  while (marker && marker.ordered === first.ordered && marker.indent <= first.indent + 1) {
    const content = [marker.text];
    const cut = marker.contentIndent;
    i++;
    while (i < lines.length) {
      const line = lines[i];
      if (isBlank(line)) {
        // A blank line ends the item unless the next text is indented under it.
        let j = i + 1;
        while (j < lines.length && isBlank(lines[j])) j++;
        if (j < lines.length && indentOf(lines[j]) >= 2 && indentOf(lines[j]) > first.indent + 1) {
          content.push(...lines.slice(i, j).map(() => ""));
          i = j;
          continue;
        }
        break;
      }
      const indent = indentOf(line);
      if (indent >= 2 && indent > first.indent + 1) {
        content.push(line.slice(Math.min(indent, cut)));
        i++;
        continue;
      }
      if (startsBlock(line) || listMarker(line)) break; // a sibling item ("2." too), heading, fence…
      content.push(line.trim()); // lazy continuation of the item's text
      i++;
    }
    items.push(parseBlocks(content, depth + 1));

    // The list goes on across blank lines while the next text is a sibling.
    let j = i;
    while (j < lines.length && isBlank(lines[j])) j++;
    marker = j < lines.length ? listMarker(lines[j]) : null;
    if (marker && marker.ordered === first.ordered && marker.indent <= first.indent + 1) i = j;
    else marker = null;
  }
  return { list: { type: "list" as const, ordered: first.ordered, start: first.start, items }, next: i };
}

// ── inlines ─────────────────────────────────────────────────────────────────

const PUNCT = /[!-/:-@[-`{-~]/;
const isSpace = (c: string | undefined) => c === undefined || /\s/.test(c);
const isWordChar = (c: string | undefined) => c !== undefined && /[\p{L}\p{N}]/u.test(c);

function runLength(src: string, at: number, ch: string): number {
  let n = 0;
  while (src[at + n] === ch) n++;
  return n;
}

/** Shared per-parse state: closers already proven absent (by delimiter). */
type Misses = Set<string>;

function findCodeClose(src: string, from: number, run: number, misses: Misses): number {
  const key = `code${run}`;
  if (misses.has(key)) return -1;
  let j = from;
  while (j < src.length) {
    if (src[j] === "`") {
      const n = runLength(src, j, "`");
      if (n === run) return j;
      j += n;
    } else j++;
  }
  misses.add(key);
  return -1;
}

/** The closing delimiter for an emphasis opened at `from` (exact run length). */
function findEmphasisClose(src: string, from: number, ch: string, len: number, misses: Misses): number {
  const key = `${ch}${len}`;
  if (misses.has(key)) return -1;
  let j = from;
  while (j < src.length) {
    const c = src[j];
    if (c === "\\") {
      j += 2;
      continue;
    }
    if (c === ch) {
      const n = runLength(src, j, ch);
      const rightFlanking = !isSpace(src[j - 1]);
      const intraword = ch === "_" && isWordChar(src[j + n]);
      if (n === len && rightFlanking && !intraword && j > from) return j;
      j += n;
      continue;
    }
    j++;
  }
  misses.add(key);
  return -1;
}

/** `[text](url "title")` starting at `at`, or null. */
function matchLink(src: string, at: number): { text: string; url: string; end: number } | null {
  let depth = 0;
  let j = at + 1;
  const textLimit = Math.min(src.length, at + 1 + MAX_LINK_TEXT);
  for (; j < textLimit; j++) {
    const c = src[j];
    if (c === "\\") {
      j++;
      continue;
    }
    if (c === "[") depth++;
    else if (c === "]") {
      if (depth === 0) break;
      depth--;
    }
  }
  if (src[j] !== "]" || src[j + 1] !== "(") return null;
  const text = src.slice(at + 1, j);
  let k = j + 2;
  while (src[k] === " ") k++;
  let url = "";
  const urlLimit = Math.min(src.length, k + MAX_LINK_URL);
  if (src[k] === "<") {
    const close = src.indexOf(">", k);
    if (close === -1 || close > urlLimit) return null;
    url = src.slice(k + 1, close);
    k = close + 1;
  } else {
    let parens = 0;
    const startUrl = k;
    for (; k < urlLimit; k++) {
      const c = src[k];
      if (/\s/.test(c)) break;
      if (c === "(") parens++;
      else if (c === ")") {
        if (parens === 0) break;
        parens--;
      }
    }
    url = src.slice(startUrl, k);
  }
  while (src[k] === " ") k++;
  const quote = src[k];
  if (quote === '"' || quote === "'") {
    const close = src.indexOf(quote, k + 1);
    if (close === -1 || close > urlLimit + MAX_LINK_TEXT) return null;
    k = close + 1;
    while (src[k] === " ") k++;
  }
  if (src[k] !== ")") return null;
  return { text, url, end: k + 1 };
}

export function parseInline(src: string, depth = 0, inLink = false, misses: Misses = new Set()): MdInline[] {
  const out: MdInline[] = [];
  let buf = "";
  const flush = () => {
    if (buf) out.push({ type: "text", text: buf });
    buf = "";
  };

  let i = 0;
  while (i < src.length) {
    const ch = src[i];

    if (ch === "\\" && PUNCT.test(src[i + 1] ?? "")) {
      buf += src[i + 1];
      i += 2;
      continue;
    }

    if (ch === "`") {
      const run = runLength(src, i, "`");
      const close = findCodeClose(src, i + run, run, misses);
      if (close === -1) {
        buf += src.slice(i, i + run);
        i += run;
        continue;
      }
      flush();
      let code = src.slice(i + run, close).replace(/\n/g, " ");
      if (code.length > 2 && code.startsWith(" ") && code.endsWith(" ") && code.trim()) code = code.slice(1, -1);
      out.push({ type: "code", text: code });
      i = close + run;
      continue;
    }

    if (ch === "[" && !inLink && depth < MAX_INLINE_DEPTH) {
      const link = matchLink(src, i);
      if (link) {
        flush();
        const safe = safeHref(link.url.trim());
        const children = link.text.trim() ? parseInline(link.text, depth + 1, true) : [{ type: "text" as const, text: link.url }];
        if (safe) out.push({ type: "link", href: safe.href, external: safe.external, children });
        else out.push(...children); // not http(s): the words, never an anchor
        i = link.end;
        continue;
      }
    }

    if ((ch === "*" || ch === "_") && depth < MAX_INLINE_DEPTH) {
      const run = runLength(src, i, ch);
      const opensWord = !isSpace(src[i + run]);
      const intraword = ch === "_" && isWordChar(src[i - 1]);
      if (opensWord && !intraword && run <= 2) {
        const close = findEmphasisClose(src, i + run, ch, run, misses);
        if (close !== -1) {
          flush();
          const children = parseInline(src.slice(i + run, close), depth + 1, inLink);
          out.push(run === 2 ? { type: "strong", children } : { type: "em", children });
          i = close + run;
          continue;
        }
      }
      buf += src.slice(i, i + run);
      i += run;
      continue;
    }

    buf += ch;
    i++;
  }
  flush();
  return out;
}

// ── React ───────────────────────────────────────────────────────────────────

/**
 * Class names, in the site's glass language (the docs' DocBlocks idiom).
 * apps/admin's stylesheet `@source`s this folder so Tailwind generates them
 * there too — the preview wears the same classes as the page.
 */
const CLS = {
  root: "space-y-4 text-[15.5px] leading-[1.75] text-muted-foreground",
  p: "text-pretty",
  h: "pt-3 text-lg font-semibold tracking-[-0.01em] text-foreground",
  hSub: "pt-2 text-[15.5px] font-semibold tracking-[-0.005em] text-foreground",
  ul: "list-disc space-y-1.5 pl-5 marker:text-white/30",
  ol: "list-decimal space-y-1.5 pl-5 marker:text-white/40",
  li: "pl-1 [&>div]:mt-2",
  quote: "space-y-3 border-l-2 border-white/15 pl-4 text-foreground/75",
  pre: "overflow-x-auto rounded-xl border border-white/10 bg-white/[0.045] p-4 font-mono text-[13px] leading-relaxed text-foreground/90",
  hr: "border-white/10",
  strong: "font-semibold text-foreground",
  em: "italic",
  code: "rounded-md border border-white/10 bg-white/[0.06] px-1.5 py-0.5 font-mono text-[0.86em] text-foreground/90",
  a: "font-medium text-foreground underline decoration-white/25 underline-offset-4 transition-colors hover:decoration-white/70",
} as const;

function renderInlines(nodes: MdInline[]): ReactNode[] {
  return nodes.map((node, i) => {
    switch (node.type) {
      case "text":
        return node.text;
      case "strong":
        return createElement("strong", { key: i, className: CLS.strong }, ...renderInlines(node.children));
      case "em":
        return createElement("em", { key: i, className: CLS.em }, ...renderInlines(node.children));
      case "code":
        return createElement("code", { key: i, className: CLS.code }, node.text);
      case "link":
        return createElement(
          "a",
          {
            key: i,
            href: node.href,
            className: CLS.a,
            ...(node.external ? { target: "_blank", rel: "noopener noreferrer" } : {}),
          },
          ...renderInlines(node.children),
        );
    }
  });
}

/** Markdown `#`/`##` → the base heading, `###`+ → one below it (capped at h6). */
function headingTag(level: number, base: number): { tag: string; sub: boolean } {
  const sub = level >= 3;
  return { tag: `h${Math.min(6, base + (sub ? 1 : 0))}`, sub };
}

function renderBlocks(blocks: MdBlock[], base: number): ReactNode[] {
  return blocks.map((block, i) => {
    switch (block.type) {
      case "paragraph":
        return createElement("p", { key: i, className: CLS.p }, ...renderInlines(block.children));
      case "heading": {
        const { tag, sub } = headingTag(block.level, base);
        return createElement(tag, { key: i, className: sub ? CLS.hSub : CLS.h }, ...renderInlines(block.children));
      }
      case "list":
        return createElement(
          block.ordered ? "ol" : "ul",
          { key: i, className: block.ordered ? CLS.ol : CLS.ul, ...(block.ordered && block.start !== 1 ? { start: block.start } : {}) },
          ...block.items.map((item, j) => {
            // A one-paragraph item renders tight (its text straight in the <li>).
            const [head, ...rest] = item;
            const lead = head?.type === "paragraph" ? renderInlines(head.children) : renderBlocks(head ? [head] : [], base);
            return createElement(
              "li",
              { key: j, className: CLS.li },
              ...lead,
              ...(rest.length ? [createElement("div", { key: "rest", className: "space-y-2" }, ...renderBlocks(rest, base))] : []),
            );
          }),
        );
      case "quote":
        return createElement("blockquote", { key: i, className: CLS.quote }, ...renderBlocks(block.children, base));
      case "code":
        return createElement(
          "pre",
          { key: i, className: CLS.pre },
          createElement("code", null, block.text),
        );
      case "rule":
        return createElement("hr", { key: i, className: CLS.hr });
    }
  });
}

/**
 * An entry body, rendered. `headingBase` is the HTML level a Markdown `#`
 * becomes, so the body nests under whatever heading the page gave the entry.
 */
export function ChangelogMarkdown({
  source,
  headingBase = 2,
  className = "",
}: {
  source: string;
  headingBase?: number;
  className?: string;
}) {
  const blocks = parseMarkdown(source);
  if (blocks.length === 0) return null;
  return createElement("div", { className: `${CLS.root} ${className}`.trim() }, ...renderBlocks(blocks, headingBase));
}

// ── HTML string (the RSS feed) ──────────────────────────────────────────────

export function escapeHtml(text: string): string {
  return text
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

function inlinesToHtml(nodes: MdInline[]): string {
  return nodes
    .map((node) => {
      switch (node.type) {
        case "text":
          return escapeHtml(node.text);
        case "strong":
          return `<strong>${inlinesToHtml(node.children)}</strong>`;
        case "em":
          return `<em>${inlinesToHtml(node.children)}</em>`;
        case "code":
          return `<code>${escapeHtml(node.text)}</code>`;
        case "link":
          return `<a href="${escapeHtml(node.href)}"${node.external ? ' rel="noopener noreferrer"' : ""}>${inlinesToHtml(node.children)}</a>`;
      }
    })
    .join("");
}

function blocksToHtml(blocks: MdBlock[], base: number): string {
  return blocks
    .map((block) => {
      switch (block.type) {
        case "paragraph":
          return `<p>${inlinesToHtml(block.children)}</p>`;
        case "heading": {
          const { tag } = headingTag(block.level, base);
          return `<${tag}>${inlinesToHtml(block.children)}</${tag}>`;
        }
        case "list": {
          const tag = block.ordered ? "ol" : "ul";
          const start = block.ordered && block.start !== 1 ? ` start="${block.start}"` : "";
          const items = block.items
            .map(([head, ...rest]) => {
              const lead = head?.type === "paragraph" ? inlinesToHtml(head.children) : blocksToHtml(head ? [head] : [], base);
              return `<li>${lead}${blocksToHtml(rest, base)}</li>`;
            })
            .join("");
          return `<${tag}${start}>${items}</${tag}>`;
        }
        case "quote":
          return `<blockquote>${blocksToHtml(block.children, base)}</blockquote>`;
        case "code":
          return `<pre><code>${escapeHtml(block.text)}</code></pre>`;
        case "rule":
          return "<hr>";
      }
    })
    .join("\n");
}

/** The same tree as escaped HTML, for feed readers (RSS `content:encoded`). */
export function markdownToHtml(source: string, headingBase = 2): string {
  return blocksToHtml(parseMarkdown(source), headingBase);
}
