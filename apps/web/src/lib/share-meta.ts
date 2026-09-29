import { createServerFn } from "@tanstack/react-start";
import { getRequestHeader } from "@tanstack/react-start/server";

import { API_URL } from "@/lib/api-url";

/**
 * Fetch a share's public metadata ON THE SERVER, forwarding the host the page
 * is rendering on. A customer's custom domain may only serve that customer's
 * videos — the API enforces it from the X-Share-Host header — so the fetch
 * must happen where the host is known, not in the browser.
 */
export const fetchShareMeta = createServerFn({ method: "GET" })
  .validator((videoId: string) => {
    if (!/^[A-Za-z0-9_-]{4,64}$/.test(videoId)) throw new Error("Invalid video id");
    return videoId;
  })
  // Returned as the raw JSON text: the server-fn serializer wants a closed
  // shape, and the loaders already own the VideoMeta type.
  .handler(async ({ data: videoId }): Promise<string | null> => {
    let host: string | undefined;
    try {
      host = getRequestHeader("host") ?? undefined;
    } catch {
      host = undefined;
    }
    try {
      const res = await fetch(`${API_URL}/api/video/${encodeURIComponent(videoId)}/meta`, {
        headers: host ? { "X-Share-Host": host } : {},
      });
      if (!res.ok) return null;
      return await res.text();
    } catch {
      return null;
    }
  });
