/**
 * DEV-ONLY: /editor-lab/open — the REAL editor page (EditorPage) without the
 * login gate, for local development. `/editor-lab/open` lists this Mac's
 * projects; `/editor-lab/open?id=<UUID>` opens one. Attached by labRoutes.tsx
 * inside an `import.meta.env.DEV` branch, so it never ships.
 */
import { EditorPage } from "../ui/EditorPage";
import { ProjectPicker } from "../ui/picker/ProjectPicker";

export default function OpenProjectLab() {
  const id = typeof window === "undefined" ? null : new URLSearchParams(window.location.search).get("id");
  return id ? <EditorPage projectId={id} /> : <ProjectPicker linkBase="/editor-lab/open" />;
}
