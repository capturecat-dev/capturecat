# Competitor research → src/lib/competitors.ts

The comparison, alternatives, and best-of pages are generated from these files.

- `BRIEF.md`: the research brief (rules, cell definitions, CaptureCat facts). Every
  non-null cell must come from a source URL, preferably the competitor's own site.
- `batch-*.json`: the sourced research, one object per product (checked 2026-10-06).
- `gen.py`: merges the batches, applies the hand-verified `PATCHES` / `TEXT_PATCHES`,
  drops `BLOCKED_SOURCES`, sorts by category, and writes the TypeScript.

Regenerate after editing a batch or a patch:

    python3 scripts/competitors/gen.py src/lib/competitors.ts

Then bump `FACTS_CHECKED` in `src/lib/pseo-content.ts`, run `npm run typecheck`, and
read the diff. Never hand-edit `competitors.ts`; it is overwritten.
