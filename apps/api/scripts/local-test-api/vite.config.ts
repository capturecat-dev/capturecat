/**
 * vite-node config for the local test API (server.ts): the Worker entrypoint
 * with its three outside dependencies swapped for test doubles, exactly as
 * the API's vitest suites mock them (src/mcp/project-tools.test.ts):
 *   cloudflare:workers → workers-stub.ts
 *   src/lib/auth       → src/test-support/fake-session.ts (Bearer <uid>)
 *   src/lib/presign    → presign-shim.ts (URLs back to this server)
 */
import { defineConfig, type Plugin } from "vite";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const src = resolve(here, "../../src");
const swaps: Record<string, string> = {
  [resolve(src, "lib/auth.ts")]: resolve(src, "test-support/fake-session.ts"),
  [resolve(src, "lib/presign.ts")]: resolve(here, "presign-shim.ts"),
};

function testDoubles(): Plugin {
  return {
    name: "capturecat-local-test-doubles",
    enforce: "pre",
    async resolveId(source, importer, options) {
      if (source === "cloudflare:workers") return resolve(here, "workers-stub.ts");
      if (!importer || !source.startsWith(".")) return null;
      const resolved = await this.resolve(source, importer, { ...options, skipSelf: true });
      if (!resolved) return null;
      const swap = swaps[resolved.id];
      // The shim itself imports the real presign module.
      if (swap && importer !== swap) return swap;
      return null;
    },
  };
}

export default defineConfig({ plugins: [testDoubles()] });
