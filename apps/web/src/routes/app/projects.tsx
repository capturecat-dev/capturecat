import { createFileRoute } from "@tanstack/react-router";

import { EditorProjects } from "@/components/dashboard/editor-projects";

export const Route = createFileRoute("/app/projects")({
  component: EditorProjects,
  head: () => ({ meta: [{ title: "Projects — CaptureCat" }] }),
});
