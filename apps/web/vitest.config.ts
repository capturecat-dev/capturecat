import { defineConfig } from "vitest/config";
import tsConfigPaths from "vite-tsconfig-paths";

// Vitest runs WITHOUT the app's Vite plugins (Cloudflare/TanStack Start):
// the editor core is pure TypeScript and its suites need nothing but Node.
// Golden vectors are loaded with import.meta.glob from the gitignored
// `.fixtures/vectors/` (see src/editor/core/vectors/harness.ts).
export default defineConfig({
  // The app's `@/…` aliases (tsconfig paths) — state/ modules import them.
  plugins: [tsConfigPaths({ projects: ["./tsconfig.json"] })],
  test: {
    include: ["src/editor/**/*.test.ts"],
    environment: "node",
    testTimeout: 60_000,
  },
});
