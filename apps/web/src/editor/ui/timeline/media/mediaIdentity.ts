/**
 * Cache identity of a media file: the thing that stays the same when the
 * same bytes are opened again, even through a fresh presigned URL.
 *
 *  - cloud media: the SHA-256 the Mac uploaded it under (content hash);
 *  - any other http(s) URL: origin + path + query with presigning /
 *    expiry parameters removed (the dev server's `?ref=` stays — it IS the
 *    identity there);
 *  - blob: / data: URLs: null — session-only, never persisted.
 */
import { resolveMediaRef, type MediaUrls } from "../../../state/cloud";

/** Query parameters that sign or expire a URL rather than name the file. */
const SIGNING_PARAM = /^(x-amz-.*|x-goog-.*|signature|expires|key-pair-id|policy|awsaccesskeyid|se|sig|sp|sv|st|sr|skoid|sktid|skt|ske|sks|skv|token|exp|hmac)$/i;

export function urlIdentity(url: string, base?: string): string | null {
  let u: URL;
  try {
    u = new URL(url, base ?? (typeof location !== "undefined" ? location.href : undefined));
  } catch {
    return null;
  }
  if (u.protocol !== "http:" && u.protocol !== "https:") return null;
  for (const k of [...u.searchParams.keys()]) if (SIGNING_PARAM.test(k)) u.searchParams.delete(k);
  u.searchParams.sort();
  const q = u.searchParams.toString();
  return `url:${u.origin}${u.pathname}${q ? `?${q}` : ""}`;
}

export function mediaIdentity(
  cloud: Pick<MediaUrls, "media" | "sources"> | undefined,
  ref: string,
  url: string,
): string | null {
  if (cloud) {
    const file = resolveMediaRef(cloud, ref);
    if (file?.sha256) return `sha256:${file.sha256.toLowerCase()}`;
  }
  return urlIdentity(url);
}

/** Absolute form of a (possibly relative) media URL, for the worker. */
export function absoluteUrl(url: string): string {
  try {
    return new URL(url, typeof location !== "undefined" ? location.href : undefined).href;
  } catch {
    return url;
  }
}
