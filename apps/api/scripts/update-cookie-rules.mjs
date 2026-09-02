#!/usr/bin/env node
/**
 * update-cookie-rules.mjs — regenerate the shared cookie-banner hide list.
 *
 * Fetches the EasyList Cookie List (AdBlock filter syntax), extracts the
 * plain-CSS element-hiding rules, and writes ONE generated JSON artifact to
 * BOTH consumers (identical bytes — the script is the single source):
 *
 *   apps/api/src/lib/screenshot/cookie-rules.generated.json   (worker import)
 *   apps/macos/CaptureCat/Resources/cookie-rules.generated.json (app bundle)
 *
 * plus COOKIE-RULES-ATTRIBUTION.txt (licence/attribution) alongside each.
 *
 * What is kept:
 *   ##selector              → "generic" (applies everywhere)
 *   dom1,dom2##selector     → "domains" map (positive domains only)
 * What is dropped (counted in meta.counts):
 *   comments, [Adblock] header, network rules (no ##)
 *   #@# exceptions, #?#/#$#/#%# extended/scriptlet rules, ##+js(...)
 *   rules whose only domains are negations (~domain), and the negated
 *     entries of mixed lists (we cannot honour "everywhere except X" safely)
 *   selectors that fail postcss-selector-parser, use adblock-extended
 *     pseudo-classes, or contain `{`/`}`/`<` (style-tag injection safety)
 *
 * Re-run with:  node scripts/update-cookie-rules.mjs
 */
import { writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const selectorParser = require("postcss-selector-parser");

const SOURCE_URL = "https://secure.fanboy.co.nz/fanboy-cookiemonster.txt";
const apiRoot = join(dirname(fileURLToPath(import.meta.url)), "..");
const repoRoot = join(apiRoot, "..", "..");
const OUT_PATHS = [
  join(apiRoot, "src/lib/screenshot/cookie-rules.generated.json"),
  join(repoRoot, "apps/macos/CaptureCat/Resources/cookie-rules.generated.json"),
];

// AdBlock-extended pseudo-classes that are not plain CSS (":has(" IS plain
// CSS in current WebKit/Chromium and is kept).
const EXTENDED_PSEUDO =
  /:(?:-abp-|has-text|contains|matches-css|matches-attr|matches-path|matches-media|xpath|style|remove|upward|min-text-length|nth-ancestor|watch-attr|others|not-visible|visible)\b/;

const parser = selectorParser();
function isValidSelector(sel) {
  if (/[{}<]/.test(sel)) return false;
  if (EXTENDED_PSEUDO.test(sel)) return false;
  try {
    parser.processSync(sel);
    return true;
  } catch {
    return false;
  }
}

const text = await (await fetch(SOURCE_URL)).text();
const headerMeta = {};
for (const line of text.split("\n").slice(0, 20)) {
  const m = line.match(/^! (Title|Last modified|License|Homepage): (.+)$/);
  if (m) headerMeta[m[1]] = m[2].trim();
}

const generic = new Set();
const domains = new Map(); // domain -> Set(selectors)
const counts = {
  keptGeneric: 0,
  keptDomainRules: 0,
  droppedExceptions: 0,
  droppedExtendedSyntax: 0,
  droppedInvalidSelector: 0,
  droppedNegatedDomainOnly: 0,
  skippedNetworkOrComment: 0,
};

for (const raw of text.split("\n")) {
  const line = raw.trim();
  if (!line || line.startsWith("!") || line.startsWith("[")) {
    counts.skippedNetworkOrComment++;
    continue;
  }
  if (line.includes("#@#")) {
    counts.droppedExceptions++;
    continue;
  }
  if (/#[?$%]#/.test(line) || line.includes("##+js(")) {
    counts.droppedExtendedSyntax++;
    continue;
  }
  const idx = line.indexOf("##");
  if (idx < 0) {
    counts.skippedNetworkOrComment++; // network rule
    continue;
  }
  const domainPart = line.slice(0, idx);
  const selector = line.slice(idx + 2).trim();
  if (!selector || !isValidSelector(selector)) {
    counts.droppedInvalidSelector++;
    continue;
  }
  if (domainPart === "") {
    generic.add(selector);
    continue;
  }
  // Positive domains only; entries with wildcards or negations are dropped.
  const doms = domainPart
    .split(",")
    .map((d) => d.trim().toLowerCase())
    .filter((d) => d && !d.startsWith("~") && !d.includes("*"));
  if (doms.length === 0) {
    counts.droppedNegatedDomainOnly++;
    continue;
  }
  for (const d of doms) {
    if (!domains.has(d)) domains.set(d, new Set());
    domains.get(d).add(selector);
    counts.keptDomainRules++;
  }
}
counts.keptGeneric = generic.size;

const out = {
  meta: {
    source: SOURCE_URL,
    title: headerMeta["Title"] ?? "Easylist Cookie List",
    sourceLastModified: headerMeta["Last modified"] ?? null,
    sourceLicense: headerMeta["License"] ?? null,
    homepage: headerMeta["Homepage"] ?? "https://easylist.to/",
    license:
      "EasyList Cookie List is dual-licensed GPLv3 / CC BY-SA 3.0 (see easylist.to); the fetched file header states " +
      (headerMeta["License"] ?? "CC BY 3.0"),
    fetchedAt: new Date().toISOString(),
    generator: "apps/api/scripts/update-cookie-rules.mjs",
    counts,
  },
  generic: [...generic].sort(),
  domains: Object.fromEntries(
    [...domains.entries()].sort(([a], [b]) => a.localeCompare(b)).map(([d, s]) => [d, [...s].sort()]),
  ),
};

const attribution = `Cookie-banner hide rules derived from the EasyList Cookie List.

Source:        ${SOURCE_URL}
Homepage:      ${out.meta.homepage}
List title:    ${out.meta.title}
Last modified: ${out.meta.sourceLastModified}
Fetched:       ${out.meta.fetchedAt}

Licence: the EasyList Cookie List is dual-licensed under the
GNU General Public License v3 (https://www.gnu.org/licenses/gpl-3.0.html)
and Creative Commons Attribution-ShareAlike 3.0 (https://creativecommons.org/licenses/by-sa/3.0/).
The fetched file's own header states: ${out.meta.sourceLicense}

The generated JSON (cookie-rules.generated.json) is a mechanical conversion of
that list's plain-CSS element-hiding rules; all credit to the EasyList authors.
Regenerate with: node apps/api/scripts/update-cookie-rules.mjs
`;

const json = JSON.stringify(out, null, 1) + "\n";
for (const p of OUT_PATHS) {
  mkdirSync(dirname(p), { recursive: true });
  writeFileSync(p, json);
  writeFileSync(join(dirname(p), "COOKIE-RULES-ATTRIBUTION.txt"), attribution);
  console.log("wrote", p, `(${(json.length / 1024).toFixed(0)} KB)`);
}
console.log(JSON.stringify(counts, null, 2));
console.log("domains:", Object.keys(out.domains).length);
