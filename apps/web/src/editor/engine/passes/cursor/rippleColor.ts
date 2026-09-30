/**
 * The click-ripple colour exactly as the exporter lays it down.
 *
 * `renderClickRipple` builds `CGColor(red:green:blue:alpha:)` from
 * `settings.clickRippleColor` — a colour in **Generic RGB**
 * (`kCGColorSpaceGenericRGB`, probed on macOS 26.2), NOT sRGB — and paints it
 * into an sRGB bitmap context, so ColorSync converts it: Generic RGB is a
 * gamma-1.80078125 matrix/TRC profile, so e.g. (1, 0.8, 0.1) lands as sRGB
 * (1, 0.8291, 0.1187) = bytes (255, 211, 30), not (255, 204, 26).
 *
 * The matrix is inv(sRGB colorants) · (Generic RGB colorants), both read from
 * the profiles' rXYZ/gXYZ/bXYZ tags (D50 PCS, s15Fixed16); the sRGB TRC is the
 * analytic curve (the profile's 1024-entry table approximates it). Matches
 * `CGColor.converted(to: sRGB)` within 2e-4 (rippleColor.test.ts, values from
 * the Swift probe) — far inside one 8-bit step.
 */
const GENERIC_TO_SRGB: readonly number[] = [
  1.0252521192065478, -0.026561770636452986, 0.0013006288137804023,
  0.019407870427636306, 0.9480428846407376, 0.03259330051315311,
  -0.0017629181045961222, -0.00143645157511757, 1.003214924435504,
];
const GENERIC_GAMMA = 1.80078125;

function encodeSRGB(v: number): number {
  const c = Math.max(0, Math.min(1, v));
  return c <= 0.0031308 ? 12.92 * c : 1.055 * Math.pow(c, 1 / 2.4) - 0.055;
}

/** Generic RGB (straight, 0…1) → encoded sRGB, clipped like ColorSync. */
export function genericRGBToSRGB(r: number, g: number, b: number): [number, number, number] {
  const lin = [r, g, b].map((v) => Math.pow(Math.max(0, Math.min(1, v)), GENERIC_GAMMA));
  const m = GENERIC_TO_SRGB;
  return [
    encodeSRGB(m[0] * lin[0] + m[1] * lin[1] + m[2] * lin[2]),
    encodeSRGB(m[3] * lin[0] + m[4] * lin[1] + m[5] * lin[2]),
    encodeSRGB(m[6] * lin[0] + m[7] * lin[1] + m[8] * lin[2]),
  ];
}
