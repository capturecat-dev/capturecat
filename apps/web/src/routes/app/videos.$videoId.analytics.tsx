import { createFileRoute } from "@tanstack/react-router";

import { VideoAnalytics } from "@/components/dashboard/video-analytics";

export const Route = createFileRoute("/app/videos/$videoId/analytics")({
  component: VideoAnalyticsPage,
  head: () => ({ meta: [{ title: "Video Analytics — CaptureCat" }] }),
});

function VideoAnalyticsPage() {
  const { videoId } = Route.useParams();
  return <VideoAnalytics videoId={videoId} />;
}
