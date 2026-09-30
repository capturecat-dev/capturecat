/**
 * Where editor projects come from. Project ids are the Mac app's project
 * UUIDs — the same id in project.json, the Mac's folder name, the cloud row
 * and the URL (`/app/editor/<UUID>`).
 *
 *  - CLOUD: projects the Mac synced with "Open in Web Editor"
 *    (state/cloud.ts; media via presigned R2 URLs).
 *  - LOCAL (dev server only): the Mac app's own projects on this machine,
 *    served read-only by the `/__dev/local-projects` Vite middleware
 *    (apps/web/vite/localProjects.ts). Never present in production builds.
 *
 * Both resolve every project.json media reference (file:// URLs, absolute
 * paths, folder-relative names) to a URL the engine can fetch.
 */
import { listCloudProjects, loadCloudProject, resolveMediaRef, type LoadedCloudProject } from "./cloud";

export type ProjectOrigin = "cloud" | "local";

export interface EditorProjectSummary {
  id: string;
  name: string;
  duration: number;
  updatedAt: string | null;
  aspectRatio: string;
  origin: ProjectOrigin;
  thumbnailUrl?: string | null;
}

export interface LoadedEditorProject {
  id: string;
  origin: ProjectOrigin;
  /** project.json exactly as stored (saves must round-trip it losslessly). */
  text: string;
  document: Record<string, unknown>;
  /** Cloud revision for optimistic saves; null for local projects. */
  revision: number | null;
  /** project.json reference → fetchable URL (undefined = not available). */
  mediaUrl(ref: string | null | undefined): string | undefined;
  cloud?: LoadedCloudProject;
}

const LOCAL_BASE = "/__dev/local-projects";

async function listLocalProjects(): Promise<EditorProjectSummary[]> {
  if (!import.meta.env.DEV) return [];
  try {
    const res = await fetch(LOCAL_BASE, { cache: "no-store" });
    if (!res.ok) return [];
    const body = (await res.json()) as {
      projects: Array<{ id: string; name: string; duration: number; updatedAt: string | null; aspectRatio: string; thumbnail: string | null }>;
    };
    return body.projects.map((p) => ({
      id: p.id,
      name: p.name,
      duration: p.duration,
      updatedAt: p.updatedAt,
      aspectRatio: p.aspectRatio,
      origin: "local" as const,
      thumbnailUrl: p.thumbnail,
    }));
  } catch {
    return [];
  }
}

async function listCloud(): Promise<EditorProjectSummary[]> {
  try {
    const { projects } = await listCloudProjects();
    return projects.map((p) => ({
      id: p.projectId,
      name: p.name,
      duration: 0,
      updatedAt: p.updatedAt ?? null,
      aspectRatio: "Auto",
      origin: "cloud" as const,
    }));
  } catch {
    // Signed out, API down, or no cloud plan — the list is simply empty.
    return [];
  }
}

/** Cloud projects, plus (dev server only) this Mac's local projects. A
 *  project present in both shows once — the cloud copy wins (it saves). */
export async function listEditorProjects(): Promise<EditorProjectSummary[]> {
  const [cloud, local] = await Promise.all([listCloud(), listLocalProjects()]);
  const seen = new Set(cloud.map((p) => p.id.toUpperCase()));
  return [...cloud, ...local.filter((p) => !seen.has(p.id.toUpperCase()))];
}

async function loadLocal(id: string): Promise<LoadedEditorProject | null> {
  if (!import.meta.env.DEV) return null;
  const res = await fetch(`${LOCAL_BASE}/${encodeURIComponent(id)}/project.json`, { cache: "no-store" });
  if (!res.ok) return null;
  const text = await res.text();
  return {
    id,
    origin: "local",
    text,
    document: JSON.parse(text) as Record<string, unknown>,
    revision: null,
    mediaUrl: (ref) => (ref ? `${LOCAL_BASE}/${encodeURIComponent(id)}/media?ref=${encodeURIComponent(ref)}` : undefined),
  };
}

async function loadCloud(id: string): Promise<LoadedEditorProject> {
  const cloud = await loadCloudProject(id);
  if (cloud.document === null) {
    throw new Error("This project's upload hasn't finished yet — open it from the Mac app again.");
  }
  return {
    id,
    origin: "cloud",
    text: cloud.document,
    document: JSON.parse(cloud.document) as Record<string, unknown>,
    revision: cloud.revision,
    mediaUrl: (ref) => resolveMediaRef(cloud, ref)?.url,
    cloud,
  };
}

/** Cloud first (it is the saving copy); on the dev server, fall back to the
 *  Mac's local folder so any recording on this machine opens. */
export async function loadEditorProject(id: string): Promise<LoadedEditorProject> {
  try {
    return await loadCloud(id);
  } catch (cloudError) {
    const local = await loadLocal(id);
    if (local) return local;
    throw cloudError;
  }
}
