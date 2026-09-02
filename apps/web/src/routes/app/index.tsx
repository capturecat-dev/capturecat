import { createFileRoute } from "@tanstack/react-router";
import { z } from "zod";

import { VideoLibrary } from "@/components/dashboard/video-library";

const searchSchema = z.object({
  playlist: z.string().optional(),
});

export const Route = createFileRoute("/app/")({
  validateSearch: searchSchema,
  component: LibraryPage,
  head: () => ({ meta: [{ title: "Library — CaptureCat" }] }),
});

function LibraryPage() {
  const { playlist } = Route.useSearch();
  return <VideoLibrary playlistFilter={playlist} />;
}
