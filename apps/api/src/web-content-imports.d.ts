/**
 * lib/ai-search/analyze.ts imports the web app's competitor list
 * (apps/web/src/lib/competitors.ts) for product names. That file's type-only
 * import pulls the web content graph into this project's type check, and one
 * module there (site-url.ts) reads Vite's `import.meta.env`. Type imports are
 * erased, so none of that code is bundled into the Worker; this declaration
 * only lets `tsc` read it.
 */
interface ImportMetaEnv {
  readonly [key: string]: string | boolean | undefined;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}
