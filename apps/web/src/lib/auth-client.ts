import { createAuthClient } from "better-auth/react";
import { organizationClient } from "better-auth/client/plugins";
import { ssoClient } from "@better-auth/sso/client";

import { API_URL } from "./api-url";

/**
 * Browser-side Better Auth client — used only for signIn.social and signOut;
 * everything else reads the session server-side (see lib/session.ts).
 */
export const authClient = createAuthClient({
  baseURL: API_URL,
  // Cross-origin API: only credentialed requests carry the session cookie.
  fetchOptions: { credentials: "include" },
  // Teams + enterprise SSO (self-serve IdP registration by org admins).
  plugins: [organizationClient(), ssoClient()],
});
