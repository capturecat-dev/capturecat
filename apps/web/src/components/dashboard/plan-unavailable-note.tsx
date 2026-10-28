import type { ReactNode } from "react";
import { Link } from "@tanstack/react-router";

import { CCIcon } from "@/editor/ui/kit/ccIcon";

/**
 * "Not in your plan" for a gate the API enforces per plan (agent access,
 * webhooks). No plan chip: which plans include it is the owner's choice in
 * the admin console, so the note names none — it links to the plans.
 */
export function PlanUnavailableNote({ children }: { children: ReactNode }) {
  return (
    <div className="cc-well flex min-w-0 items-start gap-2.5 rounded-[0.875rem] px-3 py-2.5">
      <CCIcon name="info-fill" className="mt-0.5 size-4 shrink-0 text-muted-foreground" />
      <p className="min-w-0 text-xs text-muted-foreground">
        {children}{" "}
        <Link to="/app/billing" className="text-foreground underline underline-offset-4">
          See plans
        </Link>
      </p>
    </div>
  );
}
