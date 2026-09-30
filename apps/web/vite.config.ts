import { defineConfig } from "vite";
import { tanstackStart } from "@tanstack/react-start/plugin/vite";
import { cloudflare } from "@cloudflare/vite-plugin";
import viteReact from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";
import tsConfigPaths from "vite-tsconfig-paths";

import { localProjectsPlugin } from "./vite/localProjects";

export default defineConfig({
  // Own dep-optimizer cache: parallel dev servers from git worktrees symlink
  // this node_modules, and a second server re-optimizing into the shared
  // default `.vite` swapped the chunks under a running page — two Reacts,
  // "resolveDispatcher().useRef" on null (2026-09-30).
  cacheDir: process.env.CAPTURECAT_VITE_CACHE_DIR ?? "node_modules/.vite-web",
  plugins: [
    tsConfigPaths({ projects: ["./tsconfig.json"] }),
    tailwindcss(),
    // Fixed, app-unique inspector port: with the default (9229, then the
    // next free one) web and admin started by `npm run dev` race for the
    // SAME fallback port whenever 9229 is taken, and the loser crashes the
    // whole turbo run (EADDRINUSE 127.0.0.1:9232, 2026-09-30).
    cloudflare({ viteEnvironment: { name: "ssr" }, inspectorPort: 9331 }),
    tanstackStart(),
    viteReact(),
    // DEV ONLY (`apply: "serve"`): the Mac app's local projects, read-only,
    // for opening real recordings in the web editor on localhost.
    localProjectsPlugin(),
  ],
});
