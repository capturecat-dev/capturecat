import { describe, expect, it } from "vitest";

import {
  boolValue,
  charCount,
  describeValue,
  doubleValue,
  fmt,
  formatG,
  formatNumber,
  has,
  objectArrayValue,
  prefixChars,
  resultJSON,
  round3,
  swiftDoubleDescription,
  trimWhitespacesAndNewlines,
  uuidValue,
} from "./json";

describe("Swift casts on JSON values", () => {
  it("doubleValue accepts numbers only (never a JSON bool or a numeric string)", () => {
    expect(doubleValue(2)).toBe(2);
    expect(doubleValue(-0.5)).toBe(-0.5);
    expect(doubleValue(true)).toBeNull();
    expect(doubleValue("2")).toBeNull();
    expect(doubleValue(null)).toBeNull();
  });

  it("boolValue bridges NSNumber 0/1 like `as? Bool` (verified against the Mac server)", () => {
    expect(boolValue(true)).toBe(true);
    expect(boolValue(false)).toBe(false);
    expect(boolValue(1)).toBe(true);
    expect(boolValue(0)).toBe(false);
    expect(boolValue(2)).toBeNull();
    expect(boolValue(1.5)).toBeNull();
    expect(boolValue("true")).toBeNull();
  });

  it("has() treats a JSON null as present (NSNull)", () => {
    expect(has({ a: null }, "a")).toBe(true);
    expect(has({ a: undefined }, "a")).toBe(false);
    expect(has({}, "a")).toBe(false);
  });

  it("objectArrayValue fails when ANY element is not an object", () => {
    expect(objectArrayValue([{ a: 1 }])).toEqual([{ a: 1 }]);
    expect(objectArrayValue([{ a: 1 }, 3])).toBeNull();
    expect(objectArrayValue({})).toBeNull();
  });

  it("uuidValue parses UUID(uuidString:) and uppercases", () => {
    expect(uuidValue("00000000-0000-4000-8000-00000000abcd")).toBe("00000000-0000-4000-8000-00000000ABCD");
    expect(uuidValue("nope")).toBeNull();
    expect(uuidValue("{00000000-0000-4000-8000-00000000abcd}")).toBeNull();
    expect(uuidValue(5)).toBeNull();
  });
});

describe('"\\(value)" descriptions (exact Mac server output)', () => {
  it("numbers: integers exact, doubles %.16g, bools 1/0, null <null>", () => {
    expect(describeValue(1000.5)).toBe("1000.5");
    expect(describeValue(3000.0000000000005)).toBe("3000");
    expect(describeValue(-0.30000000000000004)).toBe("-0.3");
    expect(describeValue(-1e-5)).toBe("-1e-05");
    expect(describeValue(1e21)).toBe("1e+21");
    expect(describeValue(1.5e300)).toBe("1.5e+300");
    expect(describeValue(123456789012345.67)).toBe("123456789012345.7");
    expect(describeValue(1234567.891234567)).toBe("1234567.891234567");
    expect(describeValue(1e16)).toBe("10000000000000000");
    expect(describeValue(-5)).toBe("-5");
    expect(describeValue(true)).toBe("1");
    expect(describeValue(false)).toBe("0");
    expect(describeValue(null)).toBe("<null>");
    expect(describeValue("16:10")).toBe("16:10");
  });

  it("arrays and dictionaries print their old-style plist description", () => {
    expect(describeValue([1, "a b", "abc", 2.5, null, true])).toBe(
      '(\n    1,\n    "a b",\n    abc,\n    "2.5",\n    "<null>",\n    1\n)',
    );
    expect(describeValue({ b: 1, a: "x y", c: { d: [] } })).toBe(
      '{\n    a = "x y";\n    b = 1;\n    c =     {\n        d =         (\n        );\n    };\n}',
    );
    expect(describeValue({ "1": 2, "k k": 1, "": 3, "é": 4 })).toBe(
      '{\n    "" = 3;\n    1 = 2;\n    "\\U00e9" = 4;\n    "k k" = 1;\n}',
    );
    expect(describeValue([])).toBe("(\n)");
    expect(describeValue({})).toBe("{\n}");
    expect(describeValue(["q\"uote", "back\\slash", "new\nline", "😀", "_", "-5"])).toBe(
      '(\n    "q\\"uote",\n    "back\\\\slash",\n    "new\\nline",\n    "\\Ud83d\\Ude00",\n    "_",\n    "-5"\n)',
    );
  });
});

describe("number formatting", () => {
  it("fmt is %.3f with trailing zeros stripped; ∞ for non-finite", () => {
    expect(fmt(4.9)).toBe("4.9");
    expect(fmt(10)).toBe("10");
    expect(fmt(5.0009)).toBe("5.001");
    expect(fmt(0.0004)).toBe("0");
    expect(fmt(-0.0001)).toBe("-0");
    expect(fmt(Infinity)).toBe("∞");
  });

  it("formatNumber: Int when integral, else Swift's Double description", () => {
    expect(formatNumber(4)).toBe("4");
    expect(formatNumber(0.75)).toBe("0.75");
    expect(formatNumber(1.23456)).toBe("1.23456");
    expect(formatNumber(0.05)).toBe("0.05");
    expect(formatNumber(3600)).toBe("3600");
  });

  it("swiftDoubleDescription switches to exponent form below 1e-4", () => {
    expect(swiftDoubleDescription(0.0001)).toBe("0.0001");
    expect(swiftDoubleDescription(0.00001)).toBe("1e-05");
    expect(swiftDoubleDescription(1.5e-7)).toBe("1.5e-07");
    expect(swiftDoubleDescription(0.04)).toBe("0.04");
    expect(swiftDoubleDescription(2)).toBe("2.0");
    expect(swiftDoubleDescription(-0)).toBe("-0.0");
  });

  it("formatG is printf %g on the exact binary value", () => {
    expect(formatG(0.1, 16)).toBe("0.1");
    expect(formatG(100, 16)).toBe("100");
    expect(formatG(1e-5, 6)).toBe("1e-05");
    expect(formatG(123456, 3)).toBe("1.23e+05");
    expect(formatG(9.9999999, 3)).toBe("10");
    expect(formatG(-0, 16)).toBe("-0");
  });

  it("round3 rounds ties away from zero and maps non-finite to 0", () => {
    expect(round3(1.0005)).toBe(1.001);
    expect(round3(-2.5e-3)).toBe(-0.003);
    expect(round3(NaN)).toBe(0);
    expect(round3(Infinity)).toBe(0);
  });
});

describe("strings", () => {
  it("counts and truncates grapheme clusters like Swift String", () => {
    expect(charCount("é")).toBe(1);
    expect(charCount("👨‍👩‍👧")).toBe(1);
    expect(prefixChars("é".repeat(5), 2)).toBe("éé");
    expect(prefixChars("abc", 5)).toBe("abc");
  });

  it("trims whitespace and newlines like CharacterSet.whitespacesAndNewlines", () => {
    expect(trimWhitespacesAndNewlines("  \n\tHi there  ")).toBe("Hi there");
    expect(trimWhitespacesAndNewlines(" \n\t ")).toBe("");
  });
});

describe("resultJSON", () => {
  it("sorts keys recursively and maps non-finite numbers to 0", () => {
    expect(resultJSON({ b: 1, a: { d: NaN, c: [Infinity, 2] } })).toBe('{"a":{"c":[0,2],"d":0},"b":1}');
  });
});
