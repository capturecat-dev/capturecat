import { Hono } from "hono";
import type { Env, Variables } from "../types";
import { requireAuth } from "../middleware/auth";
import { readValidatedImage } from "../lib/uploads";

/**
 * Organization extras the Better Auth plugin doesn't cover: the team logo.
 * Stored in R2 at org-logos/{orgId}; the org row's `logo` column holds the
 * public GET URL below, so every consumer (dashboard, invite page) just
 * renders `organization.logo` — with an initials fallback client-side.
 */
export const orgRoutes = new Hono<{ Bindings: Env; Variables: Variables }>();

const MAX_LOGO_BYTES = 1024 * 1024;

async function memberRole(env: Env, orgId: string, uid: string): Promise<string | null> {
  const row = await env.DB
    .prepare('SELECT role FROM "member" WHERE "organizationId" = ? AND "userId" = ? LIMIT 1')
    .bind(orgId, uid)
    .first<{ role: string }>();
  return row?.role ?? null;
}

orgRoutes.put("/org/:orgId/logo", requireAuth, async (c) => {
  const orgId = c.req.param("orgId");
  const role = await memberRole(c.env, orgId, c.get("user").uid);
  if (role !== "owner" && role !== "admin") {
    return c.json({ error: "Only team owners and admins can change the logo" }, 403);
  }
  const img = await readValidatedImage(c.req, { maxBytes: MAX_LOGO_BYTES, label: "Logo" });
  if (!img.ok) return c.json({ error: img.error }, img.status);
  await c.env.R2.put(`org-logos/${orgId}`, img.bytes, {
    httpMetadata: { contentType: img.contentType },
  });
  const url = `${new URL(c.req.url).origin}/api/org/${orgId}/logo`;
  await c.env.DB
    .prepare('UPDATE "organization" SET "logo" = ? WHERE "id" = ?')
    .bind(url, orgId)
    .run();
  return c.json({ logo: url });
});

// Public: logos render on the share/invite surfaces for signed-out viewers.
orgRoutes.get("/org/:orgId/logo", async (c) => {
  const object = await c.env.R2.get(`org-logos/${c.req.param("orgId")}`);
  if (!object) return c.json({ error: "No logo" }, 404);
  const headers = new Headers();
  object.writeHttpMetadata(headers);
  headers.set("Cache-Control", "public, max-age=3600");
  return new Response(object.body, { headers });
});
