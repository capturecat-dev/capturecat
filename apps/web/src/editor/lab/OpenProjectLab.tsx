/**
 * DEV-ONLY: /editor-lab/open — the REAL editor page (EditorPage) without the
 * login gate, for local development. `/editor-lab/open` lists this Mac's
 * projects; `/editor-lab/open?id=<UUID>` opens one. Attached by labRoutes.tsx
 * inside an `import.meta.env.DEV` branch, so it never ships.
 */
import { parsePendingSeek } from "../state/pendingSeek";
import { EditorPage } from "../ui/EditorPage";
import { ProjectPicker } from "../ui/picker/ProjectPicker";

export default function OpenProjectLab() {
  const params = typeof window === "undefined" ? null : new URLSearchParams(window.location.search);
  const id = params?.get("id") ?? null;
  // `&t=<seconds>` — the same pending seek as /app/editor/<id>?t=.
  const t = parsePendingSeek(params?.get("t") ?? undefined);
  return id ? <EditorPage projectId={id} pendingSeek={t} /> : <ProjectPicker linkBase="/editor-lab/open" />;
}
