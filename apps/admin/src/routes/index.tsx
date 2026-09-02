import { createFileRoute, redirect } from "@tanstack/react-router";

/**
 * The admin console has exactly one surface today, so the root is a redirect
 * rather than a landing page nobody reads. The routes live at the root
 * (/users, not /admin/users) because this whole app is admin.capturecat.so.
 */
export const Route = createFileRoute("/")({
  beforeLoad: () => {
    throw redirect({ to: "/users" });
  },
});
