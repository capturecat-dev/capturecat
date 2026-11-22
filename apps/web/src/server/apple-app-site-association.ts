/**
 * Universal links for the CaptureCat iPhone / iPad app: a share link
 * (capturecat.so/share/<id>) tapped on a device with the app opens its
 * in-app share viewer (apps/ios/App/ShareViewer). Every other path stays on
 * the web — the file claims share pages only.
 *
 * The file itself is public/.well-known/apple-app-site-association (static
 * assets, Content-Type set in public/_headers). This serves the SAME bytes from
 * the Worker, so the path answers JSON on capturecat.so and www.capturecat.so
 * even when a request reaches the Worker instead of the asset layer (no
 * redirect: Apple's CDN does not follow one to the apex).
 */
import aasa from "../../public/.well-known/apple-app-site-association?raw";

export const AASA_PATH = "/.well-known/apple-app-site-association";

export const appleAppSiteAssociation = aasa;

export function appleAppSiteAssociationResponse(request: Request): Response {
  return new Response(request.method === "HEAD" ? null : aasa, {
    status: 200,
    headers: {
      "Content-Type": "application/json",
      "Cache-Control": "public, max-age=3600",
    },
  });
}
