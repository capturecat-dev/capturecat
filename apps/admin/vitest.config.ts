import { defineConfig } from "vitest/config";
import tsConfigPaths from "vite-tsconfig-paths";

// Pure-TypeScript suites only (no Cloudflare/TanStack plugins), like apps/web.
export default defineConfig({
  plugins: [tsConfigPaths({ projects: ["./tsconfig.json"] })],
  test: { include: ["src/**/*.test.ts"], environment: "node" },
});
