/** The API origin. Safe for client bundles — no server-only imports. */
export const API_URL =
  import.meta.env.VITE_API_URL ?? "https://api.capturecat.so";

/** The canonical marketing-site origin. */
export const SITE_URL =
  import.meta.env.VITE_SITE_URL ?? "https://capturecat.so";
