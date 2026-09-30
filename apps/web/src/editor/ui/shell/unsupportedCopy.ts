/**
 * Copy for the stage notice shown when a project uses something the web
 * engine does not draw yet (engine/contract `unsupportedFeatures`) — so a
 * project never renders differently from the Mac without saying so. Mac
 * voice: sentence case, curly apostrophes, the fix in one line.
 */
import { unsupportedFeatureName } from "../../engine/contract";

/** "A", "A and B", "A, B and C" — the Mac's list style. */
export function listPhrase(items: readonly string[]): string {
  if (items.length <= 1) return items[0] ?? "";
  return `${items.slice(0, -1).join(", ")} and ${items[items.length - 1]}`;
}

export function unsupportedNoticeCopy(features: readonly string[]): { title: string; message: string } | null {
  if (features.length === 0) return null;
  const names = features.map(unsupportedFeatureName);
  // Only the first name keeps its capital inside the sentence.
  const phrase = listPhrase(names.map((n, i) => (i === 0 ? n : n.charAt(0).toLowerCase() + n.slice(1))));
  return {
    title: "Some of this project can’t be shown on the web yet",
    message: `${phrase} won’t appear in the preview or in exports made here. Export from CaptureCat on your Mac to include ${names.length === 1 ? "it" : "them"}.`,
  };
}
