import { useEffect } from "react";

import { trpc } from "@/lib/trpc/client";
import { adminTools, registerAdminTools } from "@/lib/webmcp";

/** Registers the admin console's read-only WebMCP tools while signed in. */
export function AdminWebMcp() {
  const utils = trpc.useUtils();
  useEffect(
    () =>
      registerAdminTools(
        adminTools({
          analytics: (days) => utils.admin.analytics.fetch({ days }),
          listUsers: () => utils.admin.listUsers.fetch(),
          userActivity: (userId) => utils.admin.userActivity.fetch({ userId }),
        }),
      ),
    [utils],
  );
  return null;
}
