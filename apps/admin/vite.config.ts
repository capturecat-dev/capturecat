import { defineConfig } from "vite";
import { tanstackStart } from "@tanstack/react-start/plugin/vite";
import { cloudflare } from "@cloudflare/vite-plugin";
import viteReact from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";
import tsConfigPaths from "vite-tsconfig-paths";

export default defineConfig({
  plugins: [
    tsConfigPaths({ projects: ["./tsconfig.json"] }),
    tailwindcss(),
    // Fixed, app-unique inspector port: with the default (9229, then the
    // next free one) web and admin started by `npm run dev` race for the
    // SAME fallback port whenever 9229 is taken, and the loser crashes the
    // whole turbo run (EADDRINUSE 127.0.0.1:9232, 2026-09-30).
    cloudflare({ viteEnvironment: { name: "ssr" }, inspectorPort: 9332 }),
    tanstackStart(),
    viteReact(),
  ],
});
