/**
 * SITE_URL lives in its own module so that site-content.ts (the page registry)
 * and pseo-content.ts (the generated comparison/alternative pages) can both
 * import it without a runtime cycle: site-content imports the generated pages,
 * so the generated pages must not import site-content back at runtime.
 */
export const SITE_URL =
  import.meta.env.VITE_SITE_URL ?? "https://capturecat.so";
