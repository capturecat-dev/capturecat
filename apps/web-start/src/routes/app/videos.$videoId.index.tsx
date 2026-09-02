import { createFileRoute } from "@tanstack/react-router";

import { VideoDetails } from "@/components/dashboard/video-details";

export const Route = createFileRoute("/app/videos/$videoId/")({
  component: VideoDetailsPage,
  head: () => ({ meta: [{ title: "Video details — CaptureCat" }] }),
});

function VideoDetailsPage() {
  const { videoId } = Route.useParams();
  return <VideoDetails videoId={videoId} />;
}
