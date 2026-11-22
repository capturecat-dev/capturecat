/**
 * Type-only stand-in for `samlify`, wired in through `paths` in tsconfig.json.
 *
 * Why: @better-auth/sso 1.7's declarations `import samlify from "samlify"`,
 * samlify's own types import `@xmldom/xmldom`, and xmldom's index.d.ts opens
 * with `/// <reference lib="dom" />`. That drags the browser DOM library
 * into this Worker's program, where it shadows @cloudflare/workers-types:
 * `caches.default` stops existing and Workers' BufferSource no longer
 * accepts a plain Uint8Array — errors in files that have nothing to do with
 * SSO. `skipLibCheck` does not stop a lib reference.
 *
 * Nothing in this Worker configures SAML through samlify's types (SAML
 * providers are registered over HTTP from the web app), so `any` loses no
 * checking we use. This is TYPES ONLY: the bundle still resolves the real
 * samlify, because esbuild does not apply this tsconfig's `paths` to imports
 * made from inside node_modules.
 */
declare const samlify: any;
export default samlify;
