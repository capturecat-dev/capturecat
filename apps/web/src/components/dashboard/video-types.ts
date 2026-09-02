/** Shapes shared by the library surfaces, matching videos.list / playlists. */

export interface DashboardVideo {
  videoId: string;
  fileName: string;
  contentType: string;
  fileSizeBytes: number;
  durationSeconds: number;
  isPrivate: boolean;
  createdAt: string;
  url: string;
  projectId: string | null;
  allowDownload: boolean;
  hasPassword: boolean;
  expiresAt: string | null;
  maxViews: number | null;
  brandAccent: string | null;
  commentsEnabled: boolean;
  currentVersion: number;
  showVersionHistory: boolean;
  ctaLabel: string | null;
  ctaUrl: string | null;
  profileVisible: boolean;
  /** Content type of the owner-uploaded custom thumbnail, or null. */
  thumbnailType: string | null;
  /** Absolute API URL of the custom thumbnail image, or null. */
  thumbnailUrl: string | null;
}

export interface Playlist {
  playlistId: string;
  name: string;
  emoji: string | null;
  videoIds: string[];
}
