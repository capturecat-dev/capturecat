import { describe, it, expect } from "vitest";
import {
  mintKey,
  parseKeyToken,
  sha256Hex,
  timingSafeEqual,
  verifySecret,
  KEY_PREFIX,
} from "./keys";

describe("mintKey / parseKeyToken round-trip", () => {
  it("mints a parseable token whose stored hash matches the secret", async () => {
    const k = await mintKey();
    expect(k.token.startsWith(KEY_PREFIX)).toBe(true);
    const parsed = parseKeyToken(k.token);
    expect(parsed).not.toBeNull();
    expect(parsed!.id).toBe(k.id);
    expect(await sha256Hex(parsed!.secret)).toBe(k.keyHash);
    expect(await verifySecret(parsed!.secret, k.keyHash)).toBe(true);
  });

  it("never embeds the secret hash in the token", async () => {
    const k = await mintKey();
    expect(k.token.includes(k.keyHash)).toBe(false);
  });

  it("mints unique ids and secrets", async () => {
    const a = await mintKey();
    const b = await mintKey();
    expect(a.id).not.toBe(b.id);
    expect(a.keyHash).not.toBe(b.keyHash);
  });

  it("rejects malformed tokens", () => {
    expect(parseKeyToken("")).toBeNull();
    expect(parseKeyToken("cc_live_short_x")).toBeNull();
    expect(parseKeyToken("sk_other_prefix")).toBeNull();
    expect(parseKeyToken(KEY_PREFIX + "a".repeat(16))).toBeNull(); // no secret
    expect(parseKeyToken(KEY_PREFIX + "a".repeat(16) + "_" + "b".repeat(10))).toBeNull(); // short secret
    expect(parseKeyToken(KEY_PREFIX + "A".repeat(16) + "_" + "b".repeat(48))).toBeNull(); // bad charset
  });
});

describe("verify", () => {
  it("rejects the wrong secret", async () => {
    const k = await mintKey();
    expect(await verifySecret("x".repeat(48), k.keyHash)).toBe(false);
  });

  it("sha256Hex matches a known vector", async () => {
    // echo -n abc | shasum -a 256
    expect(await sha256Hex("abc")).toBe(
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
    );
  });

  it("timingSafeEqual: equality, inequality, length mismatch", () => {
    expect(timingSafeEqual("abcd", "abcd")).toBe(true);
    expect(timingSafeEqual("abcd", "abce")).toBe(false);
    expect(timingSafeEqual("abcd", "abc")).toBe(false);
    expect(timingSafeEqual("", "")).toBe(true);
    expect(timingSafeEqual("", "a")).toBe(false);
  });
});
