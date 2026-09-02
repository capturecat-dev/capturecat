/**
 * nanoid-style short ID generator using Web Crypto API.
 * Produces URL-safe IDs (a-z, 0-9) of configurable length.
 */

const ALPHABET = "abcdefghijklmnopqrstuvwxyz0123456789";
const DEFAULT_LENGTH = 10;

export function generateId(length: number = DEFAULT_LENGTH): string {
  const bytes = new Uint8Array(length);
  crypto.getRandomValues(bytes);
  let id = "";
  for (let i = 0; i < length; i++) {
    id += ALPHABET[bytes[i] % ALPHABET.length];
  }
  return id;
}
