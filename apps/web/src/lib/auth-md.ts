/**
 * /auth.md — how agents authenticate with CaptureCat (WorkOS auth.md,
 * https://github.com/workos/auth.md).
 *
 * Self-contained by design: CaptureCat runs no OAuth/OIDC authorization
 * server for third parties, so there is no Protected Resource Metadata or
 * `agent_auth` block to point at. The spec's fallback applies: name the
 * audience, the provisioning endpoint, the methods and how credentials are
 * used. Facts mirror lib/openapi.ts and apps/api routes/screenshot.ts.
 */
import { SITE_URL } from "./site-url";

export const AUTH_MD = `# CaptureCat auth.md

How AI agents, and the developers who build them, authenticate with CaptureCat.

## Audience

- Agents that call the CaptureCat API at \`https://api.capturecat.so\` — in
  practice the Screenshot API.
- Agents that drive the CaptureCat Mac app through its MCP server.
- Browser agents using the WebMCP tools on capturecat.so and app.capturecat.so.

There is no OAuth or OpenID Connect server for third-party agents, and no
self-service agent registration endpoint.

## Methods

| Surface | Credential | How it is used |
|---|---|---|
| Screenshot API (\`/api/screenshot/take\`) | Access key | \`X-Access-Key: <key>\` header (preferred) or \`access_key\` query parameter |
| Key management (\`/api/screenshot/keys\`) | Signed-in CaptureCat session | Session only: an access key can never create, list or revoke keys |
| Release feed, downloads, oEmbed, health | None | Public |
| MCP server (\`CaptureCat --mcp\`) | None | Local stdio inside the Mac app; acts as the user signed in to that Mac |
| WebMCP tools in the browser | The page's own session | Tools run in the user's tab, with the user's sign-in; nothing to configure |

## Provisioning an access key

1. The person who owns the account signs in to CaptureCat with Google or Apple
   (${SITE_URL}/login). Accounts are created by signing in; there is no
   password.
2. With that session, \`POST https://api.capturecat.so/api/screenshot/keys\`
   creates a key. The secret is shown once; store it in a secret manager.
3. \`GET /api/screenshot/keys\` lists keys (secrets redacted);
   \`DELETE /api/screenshot/keys/{id}\` revokes one immediately.

The account's plan must include the Screenshot API (Pro does; 1,000 renders a
month). Otherwise \`take\` answers 403 \`upgrade_required\`; past the monthly
allowance, 429 \`quota_exceeded\`.

## Using the credential

- Send the key on every request to \`/api/screenshot/take\`. A missing, unknown or
  revoked key is 401 \`unauthorized\`; there is no fallback to another credential.
- Keep keys out of URLs that are shared or logged; prefer the header.
- Treat a key as the account owner's: renders count against their quota, and
  \`store=true\` writes to their storage.

## Machine-readable

- OpenAPI 3.1: ${SITE_URL}/openapi.json
- API catalog (RFC 9727): ${SITE_URL}/.well-known/api-catalog
- Agent skills: ${SITE_URL}/.well-known/agent-skills/index.json
- Docs: ${SITE_URL}/docs/api

## Contact

contact@capturecat.so
`;
