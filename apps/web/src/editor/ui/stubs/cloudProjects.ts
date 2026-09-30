/**
 * STUB data source for the project picker and the editor route, until
 * `editor/state/cloud.ts` (cloud project list + project.json/media loading)
 * lands. Replace the two functions' bodies with the real client; the shapes
 * below are what the UI consumes.
 *
 * Production returns nothing (an honest empty state — never fake projects
 * in front of real users); dev returns a few samples so the picker can be
 * designed.
 */

export interface CloudProjectSummary {
  id: string;
  name: string;
  /** Output duration, seconds. */
  duration: number;
  /** ISO timestamp of the last save (Mac or web). */
  updatedAt: string;
  /** "16:9" etc. (AspectRatio raw value). */
  aspectRatio: string;
  /** Poster frame URL (presigned), if uploaded. */
  thumbnailUrl?: string;
  /** Source of the latest revision. */
  lastEditedOn?: "mac" | "web";
}

const DEV_SAMPLES: CloudProjectSummary[] = [
  { id: "demo-onboarding", name: "Onboarding walkthrough", duration: 94.2, updatedAt: "2026-09-29T18:04:00Z", aspectRatio: "16:9", lastEditedOn: "mac" },
  { id: "demo-bugrepro", name: "Checkout bug repro", duration: 41.6, updatedAt: "2026-09-28T11:30:00Z", aspectRatio: "16:9", lastEditedOn: "web" },
  { id: "demo-launch", name: "Launch teaser (vertical)", duration: 28.0, updatedAt: "2026-09-25T09:12:00Z", aspectRatio: "9:16", lastEditedOn: "mac" },
];

export async function listCloudProjects(): Promise<CloudProjectSummary[]> {
  return import.meta.env.DEV ? DEV_SAMPLES : [];
}

export async function getCloudProject(id: string): Promise<CloudProjectSummary | null> {
  const all = await listCloudProjects();
  return all.find((p) => p.id === id) ?? null;
}
