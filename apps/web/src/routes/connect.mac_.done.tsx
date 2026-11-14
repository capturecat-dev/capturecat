import { createFileRoute } from "@tanstack/react-router";
import { z } from "zod";

import { Button } from "@/components/ui/button";
import { CCIcon } from "@/editor/ui/kit/ccIcon";
import { CONNECT_COPY, MacAppMark, MacConnectShell } from "@/components/oauth/mac-connect-page";

/**
 * Where the browser lands after the Mac sign-in: the app's loopback listener
 * answers the code (or the error) with a redirect here instead of a page of
 * its own, so the 127.0.0.1 hop is never what the user looks at. Public — the
 * browser's session has nothing to do with the result. "Open CaptureCat" is a
 * click, so macOS lets the app come to the front. CaptureCat for iPhone and
 * iPad may land here too with `app=ios`: same screens, its own name, and no
 * "Open CaptureCat" (capturecat:// is the Mac app's scheme).
 */
const searchSchema = z.object({
  result: z.enum(["ok", "denied", "error"]).optional().catch(undefined),
  detail: z.string().max(300).optional().catch(undefined),
  app: z.enum(["mac", "ios"]).optional().catch(undefined),
});

export const Route = createFileRoute("/connect/mac_/done")({
  validateSearch: searchSchema,
  component: DoneRoute,
  head: () => ({
    meta: [
      { title: "CaptureCat for Mac" },
      { name: "robots", content: "noindex" },
    ],
  }),
});

const OPEN_APP = "capturecat://open-app";

function DoneRoute() {
  const { result = "ok", detail, app = "mac" } = Route.useSearch();
  const appName = CONNECT_COPY[app].appName;
  const copy =
    result === "ok"
      ? { icon: "check-circle-fill", tint: "text-cc-green-text", title: "You're signed in", body: `${appName} is connected to your account.` }
      : result === "denied"
        ? { icon: "info-fill", tint: "text-muted-foreground", title: "Sign-in cancelled", body: `${appName} wasn't given access. You can try again from the app.` }
        : { icon: "warning-fill", tint: "text-cc-amber-text", title: "Sign-in didn't finish", body: detail || `Something went wrong. Try again from ${appName}.` };
  return (
    <MacConnectShell>
      <div className="space-y-5 text-center">
        <div className="flex justify-center">
          <MacAppMark className="size-16" platform={app} />
        </div>
        <div className="space-y-1.5">
          <h1 className="flex items-center justify-center gap-2 text-xl font-semibold tracking-[-0.01em]">
            <CCIcon name={copy.icon} size={18} className={copy.tint} />
            {copy.title}
          </h1>
          <p className="text-sm text-muted-foreground">{copy.body}</p>
        </div>
        {app === "mac" && (
          <Button asChild>
            <a href={OPEN_APP}>Open CaptureCat</a>
          </Button>
        )}
        <p className="text-xs text-muted-foreground">You can close this tab.</p>
      </div>
    </MacConnectShell>
  );
}
