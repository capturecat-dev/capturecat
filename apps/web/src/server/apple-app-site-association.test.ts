import { describe, expect, it } from "vitest";

import { AASA_PATH, appleAppSiteAssociation, appleAppSiteAssociationResponse } from "./apple-app-site-association";

interface Component {
  "/": string;
  exclude?: boolean;
}

describe("apple-app-site-association", () => {
  const parsed = JSON.parse(appleAppSiteAssociation) as {
    applinks: { details: { appIDs: string[]; components: Component[] }[] };
  };

  it("names the iOS app (team E52HU87CX9, bundle so.capturecat.ios) and nothing else", () => {
    expect(parsed.applinks.details).toHaveLength(1);
    expect(parsed.applinks.details[0].appIDs).toEqual(["E52HU87CX9.so.capturecat.ios"]);
  });

  it("claims ONLY share pages, in both the current and the legacy format", () => {
    const detail = parsed.applinks.details[0] as { components: Component[]; paths?: string[] };
    expect(detail.components.map((c) => c["/"])).toEqual(["/share/*"]);
    expect(detail.components.some((c) => c.exclude)).toBe(false);
    expect(detail.paths).toEqual(["/share/*"]);
  });

  it("is served as application/json at the well-known path", async () => {
    expect(AASA_PATH).toBe("/.well-known/apple-app-site-association");
    const res = appleAppSiteAssociationResponse(new Request(`https://capturecat.so${AASA_PATH}`));
    expect(res.status).toBe(200);
    expect(res.headers.get("Content-Type")).toBe("application/json");
    expect(JSON.parse(await res.text())).toEqual(parsed);
  });
});
