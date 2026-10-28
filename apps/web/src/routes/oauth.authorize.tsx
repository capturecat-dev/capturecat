import { createFileRoute, redirect } from "@tanstack/react-router";
import { z } from "zod";

import { fetchSession } from "@/lib/session-fns";
import type { OAUTH_PARAMS } from "@/lib/agent-access";
import { ConsentPage } from "@/components/oauth/consent-page";

/**
 * "Sign in with CaptureCat" — the OAuth consent page. An MCP client (a
 * Claude.ai or ChatGPT connector…) is sent here by api.capturecat.so/oauth/
 * authorize with the authorization request in the query. The signed-in user
 * sees who is asking (name, logo, the verified host of a metadata-document
 * client, and where they will be sent back), narrows the permissions, and
 * allows or denies. The API re-validates the whole request on both calls
 * (apps/api/src/routes/oauth.ts) — nothing here is trusted.
 */

const param = z.string().max(2000).optional().catch(undefined);
const searchSchema = z.object({
  response_type: param,
  client_id: param,
  redirect_uri: param,
  scope: param,
  state: param,
  code_challenge: param,
  code_challenge_method: param,
  resource: param,
} satisfies Record<(typeof OAUTH_PARAMS)[number], typeof param>);

export const Route = createFileRoute("/oauth/authorize")({
  validateSearch: searchSchema,
  beforeLoad: async ({ location }) => {
    const session = await fetchSession();
    if (!session) {
      // Back here, query and all, after signing in.
      throw redirect({ to: "/login", search: { next: location.href } });
    }
    return { session };
  },
  component: ConsentRoute,
  head: () => ({
    meta: [
      { title: "Connect an app — CaptureCat" },
      { name: "robots", content: "noindex" },
    ],
  }),
});

function ConsentRoute() {
  const params = Route.useSearch();
  const { session } = Route.useRouteContext();
  return <ConsentPage params={params} email={session.user.email} />;
}
