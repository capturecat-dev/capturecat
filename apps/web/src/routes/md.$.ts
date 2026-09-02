import { createFileRoute } from "@tanstack/react-router";

import { markdownPageResponse } from "@/lib/markdown-pages";

/**
 * Markdown rendering of the public pages, at the internal /md/* paths.
 * "/md" (empty splat) → "/", "/md/pricing" → "/pricing", etc.
 */
export const Route = createFileRoute("/md/$")({
  server: {
    handlers: {
      GET: ({ params }) => {
        const splat = (params as { _splat?: string })._splat ?? "";
        const path = splat === "" ? "/" : `/${splat}`;
        return markdownPageResponse(path);
      },
    },
  },
});
