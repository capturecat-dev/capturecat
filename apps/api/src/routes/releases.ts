import { Hono } from "hono";
import type { Env } from "../types";

export const releaseRoutes = new Hono<{ Bindings: Env }>();

/**
 * GET /releases/latest
 * Returns the latest release metadata (version, download URLs).
 */
releaseRoutes.get("/releases/latest", async (c) => {
  const obj = await c.env.R2.get("releases/latest.json");
  if (!obj) {
    return c.json({ error: "No release found" }, 404);
  }

  const data = await obj.json();
  return c.json(data, 200, {
    "Cache-Control": "public, max-age=300", // cache 5 min
  });
});

/**
 * GET /releases/latest-beta
 * Latest BETA release metadata (published by publish_release.sh --beta).
 * The website's beta page and tester emails link here.
 */
releaseRoutes.get("/releases/latest-beta", async (c) => {
  const obj = await c.env.R2.get("releases/latest-beta.json");
  if (!obj) {
    return c.json({ error: "No beta release found" }, 404);
  }
  return c.json(await obj.json(), 200, {
    "Cache-Control": "public, max-age=300",
  });
});

/**
 * GET /releases/versions
 * Full public release history (both channels, newest first) from
 * releases/index.json — every listed version's DMGs remain downloadable at
 * /releases/:version/:file, so users can fetch any old build.
 */
releaseRoutes.get("/releases/versions", async (c) => {
  const obj = await c.env.R2.get("releases/index.json");
  if (!obj) {
    return c.json({ releases: [] }, 200, { "Cache-Control": "public, max-age=300" });
  }
  const data = (await obj.json()) as { releases?: unknown[] };
  // Strip Sparkle signatures from the public listing — they are feed
  // plumbing, not user-facing metadata.
  const releases = (data.releases ?? []).map((r) => {
    const { signatures: _signatures, ...rest } = r as Record<string, unknown>;
    return rest;
  });
  return c.json({ releases }, 200, {
    "Cache-Control": "public, max-age=300",
  });
});

/**
 * GET /releases/download/:arch
 * Streams the latest DMG for the given architecture directly.
 */
releaseRoutes.get("/releases/download/:arch", async (c) => {
  const arch = c.req.param("arch");
  if (arch !== "arm64" && arch !== "x86_64") {
    return c.json({ error: "Invalid architecture. Use arm64 or x86_64" }, 400);
  }

  const latestObj = await c.env.R2.get("releases/latest.json");
  if (!latestObj) {
    return c.json({ error: "No release found" }, 404);
  }

  const data = (await latestObj.json()) as { version: string };
  // Releases built before the CaptureCat rename are keyed with the old product
  // name. The next release upload writes the new key; falling back until then
  // keeps the download page working instead of 404ing every existing version.
  const key = `releases/${data.version}/CaptureCat-${arch}.dmg`;
  const dmg =
    (await c.env.R2.get(key)) ??
    (await c.env.R2.get(`releases/${data.version}/Cappd-${arch}.dmg`));

  if (!dmg) {
    return c.json({ error: "File not found" }, 404);
  }

  return new Response(dmg.body, {
    headers: {
      "Content-Type": "application/octet-stream",
      "Content-Disposition": `attachment; filename="CaptureCat.dmg"`,
      "Content-Length": String(dmg.size),
      "Cache-Control": "public, max-age=300",
    },
  });
});

/**
 * GET /releases/appcast.xml
 * Returns Sparkle appcast feed for auto-updates.
 */
releaseRoutes.get("/releases/appcast.xml", async (c) => {
  const obj = await c.env.R2.get("releases/appcast.xml");
  if (!obj) {
    return c.body("No appcast found", 404);
  }

  return new Response(obj.body, {
    headers: {
      "Content-Type": "application/xml",
      "Cache-Control": "public, max-age=300",
    },
  });
});

/**
 * GET /releases/appcast/:arch
 *
 * Per-architecture Sparkle feed. A Sparkle <item> carries ONE <enclosure> and
 * Sparkle has no architecture predicate, so a single appcast can only offer one
 * DMG — publishing just the arm64 one meant every Intel Mac auto-updated to a
 * build it could not launch. The app asks for its own arch (UpdateFeed.swift).
 *
 * `:arch` is its own path segment on purpose: Hono does not bind a parameter
 * that sits mid-segment, so `/releases/appcast-:arch.xml` silently never
 * matched and every request fell through to a 404.
 */
releaseRoutes.get("/releases/appcast/:arch", async (c) => {
  const arch = c.req.param("arch");
  if (arch !== "arm64" && arch !== "x86_64") {
    return c.json({ error: "Invalid architecture. Use arm64 or x86_64" }, 400);
  }
  const obj = await c.env.R2.get(`releases/appcast-${arch}.xml`);
  if (!obj) {
    return c.body("No appcast found", 404);
  }
  return new Response(obj.body, {
    headers: {
      "Content-Type": "application/xml",
      "Cache-Control": "public, max-age=300",
    },
  });
});

/**
 * GET /releases/:version/:file
 * Streams a release DMG directly from R2.
 */
releaseRoutes.get("/releases/:version/:file", async (c) => {
  const version = c.req.param("version");
  const file = c.req.param("file");

  // Only allow DMG files
  if (!file.endsWith(".dmg")) {
    return c.json({ error: "Not found" }, 404);
  }

  const key = `releases/${version}/${file}`;
  const obj = await c.env.R2.get(key);

  if (!obj) {
    return c.json({ error: "File not found" }, 404);
  }

  return new Response(obj.body, {
    headers: {
      "Content-Type": "application/octet-stream",
      "Content-Disposition": `attachment; filename="${file}"`,
      "Content-Length": String(obj.size),
      "Cache-Control": "public, max-age=86400",
    },
  });
});
