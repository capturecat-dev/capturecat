/**
 * Shapes of the API's moderation routes (apps/api routes/admin-moderation.ts),
 * as the Videos page reads them.
 */
export type VideoFilter = "all" | "reported" | "removed";

export interface AdminVideo {
  videoId: string;
  title: string;
  fileName: string;
  sizeBytes: number;
  durationSeconds: number;
  status: string;
  /** Who can watch it today (ignoring a takedown). */
  visibility: "private" | "password" | "public" | "unlisted";
  createdAt: string;
  hasThumbnail: boolean;
  shareUrl: string;
  owner: { id: string; email: string | null; name: string | null; blocked: boolean };
  views: number;
  openReports: number;
  lastReportAt: string | null;
  removed: { at: string; reason: string | null } | null;
}

export interface AdminVideoPage {
  videos: AdminVideo[];
  nextCursor: string | null;
  counts: { all: number; reported: number; removed: number };
}

export interface AdminVideoReport {
  id: string;
  reason: string;
  reasonLabel: string;
  details: string | null;
  signedIn: boolean;
  createdAt: string;
  resolvedAt: string | null;
  resolution: "removed" | "dismissed" | null;
}

export interface AdminVideoDetail {
  video: AdminVideo;
  reports: AdminVideoReport[];
  history: Array<{ id: string; action: "remove" | "restore" | "delete" | "dismiss"; reason: string | null; createdAt: string; adminEmail: string | null }>;
}
