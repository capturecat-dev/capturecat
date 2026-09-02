/**
 * Serialize an object for an inline `<script type="application/ld+json">`.
 *
 * Script bodies are emitted raw (TanStack renders `children` via
 * dangerouslySetInnerHTML), and JSON.stringify does not escape `<` — so a
 * value like an upload's fileName containing `</script><script>…` would break
 * out of the block and execute on this origin. Escaping `<` as `\\u003c`
 * keeps the output valid JSON while making `</script>` impossible; U+2028 and
 * U+2029 are escaped because they are line terminators in JS but not in JSON.
 */
export function jsonLd(value: unknown): string {
  return JSON.stringify(value)
    .replace(/</g, "\\u003c")
    .replace(/\u2028/g, "\\u2028")
    .replace(/\u2029/g, "\\u2029");
}
