/**
 * Shapes of the API's admin project routes (apps/api routes/admin-projects.ts),
 * as the Projects page and the Videos page's "Never shared" tab read them.
 */
export type ProjectFilter = "all" | "unshared" | "shared";

export interface AdminProject {
  projectId: string;
  name: string;
  owner: { id: string; email: string | null; name: string | null; blocked: boolean };
  team: { id: string; name: string | null } | null;
  /** False while the first upload is staged but its project.json never landed. */
  uploaded: boolean;
  revision: number;
  totalBytes: number;
  fileCount: number;
  /** Shared videos made from this project. */
  shares: number;
  lastShareAt: string | null;
  createdAt: string;
  updatedAt: string;
}

export interface AdminProjectPage {
  projects: AdminProject[];
  nextCursor: string | null;
  counts: { all: number; unshared: number; shared: number };
}

export interface AdminProjectDetail {
  project: AdminProject;
  files: Array<{ path: string; bytes: number; contentType: string; kind: "video" | "audio" | "image" | "data" }>;
  /** The file the console plays (the screen recording), if any. */
  videos: Array<{ videoId: string; title: string; status: string; createdAt: string; removed: boolean; shareUrl: string }>;
  versions: number;
  lastEditedIn: "mac" | "web" | null;
}
