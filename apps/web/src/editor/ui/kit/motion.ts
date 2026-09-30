/**
 * CCMotion for the web — one vocabulary of Apple-feel animation.
 *
 * Port of `Views/Shared/DesignKit/CCMotion.swift`:
 *  • Curves (bezier): settle (Keynote ease-out, the house curve), glide
 *    (symmetric, hover washes/colour fades), bounce (growth — settle with a
 *    ~10% overshoot; growth bounces at the PUSHED edge only).
 *  • Springs (response, dampingRatio) exactly as the Mac converts them for
 *    CASpringAnimation: mass 1, stiffness (2π/response)², damping
 *    2ζ√stiffness. Emitted as CSS `linear()` easings (so CSS transitions and
 *    WAAPI can spring without JS per frame) plus the settling duration.
 *
 * Pure math — safe on the server (the springs are serialised into inline
 * CSS variables by ThemeRoot during SSR).
 */

export type CubicBezier = readonly [number, number, number, number];

export const curves = {
  settle: [0.22, 1, 0.36, 1],
  glide: [0.4, 0, 0.2, 1],
  bounce: [0.34, 1.56, 0.64, 1],
} as const satisfies Record<string, CubicBezier>;

export const cssCurve = (c: CubicBezier) => `cubic-bezier(${c[0]}, ${c[1]}, ${c[2]}, ${c[3]})`;

/** CCMotion.Pace — divides every duration / spring response. */
export type Pace = "relaxed" | "standard" | "brisk";
export const paceValue: Record<Pace, number> = { relaxed: 0.7, standard: 1, brisk: 1.45 };

/** Standard-pace durations (seconds) the Mac call sites use. */
export const durations = {
  press: 0.08,
  quick: 0.16,
  settle: 0.28,
  run: 0.35,
  grow: 0.38,
  fadeSwap: 0.18,
} as const;

export type SpringName = "snappy" | "smooth" | "bouncy";

export interface SpringSpec {
  response: number;
  dampingRatio: number;
}

export const springs: Record<SpringName, SpringSpec> = {
  /** UI acknowledgement — fast, barely any bounce. */
  snappy: { response: 0.28, dampingRatio: 0.9 },
  /** Standard movement — Keynote "magic move". */
  smooth: { response: 0.42, dampingRatio: 1.0 },
  /** Playful — visible overshoot (toggle thumbs, pops). */
  bouncy: { response: 0.42, dampingRatio: 0.68 },
};

/** Normalised step response x(t) of the Mac's spring (0 → 1). */
export function springValue(spec: SpringSpec, t: number, pace = 1): number {
  const omega = (2 * Math.PI) / (spec.response / pace); // √(k/m), m = 1
  const zeta = spec.dampingRatio;
  if (zeta < 1) {
    const wd = omega * Math.sqrt(1 - zeta * zeta);
    const envelope = Math.exp(-zeta * omega * t);
    return 1 - envelope * (Math.cos(wd * t) + ((zeta * omega) / wd) * Math.sin(wd * t));
  }
  if (zeta === 1) {
    return 1 - Math.exp(-omega * t) * (1 + omega * t);
  }
  // Overdamped: x = 1 − (c1·e^{r1 t} + c2·e^{r2 t}), x(0) = 0, x'(0) = 0.
  const s = Math.sqrt(zeta * zeta - 1);
  const r1 = -omega * (zeta - s);
  const r2 = -omega * (zeta + s);
  const c1 = r2 / (r2 - r1);
  const c2 = 1 - c1;
  return 1 - (c1 * Math.exp(r1 * t) + c2 * Math.exp(r2 * t));
}

/** CASpringAnimation.settlingDuration-equivalent: when |x−1| stays < 0.001. */
export function springSettlingDuration(spec: SpringSpec, pace = 1): number {
  const step = 1 / 240;
  let lastOutside = 0;
  for (let t = 0; t < 4; t += step) {
    if (Math.abs(springValue(spec, t, pace) - 1) >= 0.001) lastOutside = t;
  }
  return Math.min(4, lastOutside + step);
}

/**
 * CSS `linear()` easing sampling the spring over its settling duration.
 * 64 samples is visually exact at 120 Hz for these response times.
 */
export function springEasing(spec: SpringSpec, pace = 1, samples = 64): { easing: string; duration: number } {
  const duration = springSettlingDuration(spec, pace);
  const points: string[] = [];
  for (let i = 0; i <= samples; i++) {
    const t = (i / samples) * duration;
    const v = i === samples ? 1 : springValue(spec, t, pace);
    points.push(v.toFixed(4).replace(/\.?0+$/, "") || "0");
  }
  return { easing: `linear(${points.join(", ")})`, duration };
}

/** Evaluate a cubic timing curve's y at progress x (CCMotion.bezierY). */
export function bezierY(x: number, p: CubicBezier): number {
  if (x <= 0) return 0;
  if (x >= 1) return 1;
  const coord = (a: number, b: number, t: number) => {
    const u = 1 - t;
    return 3 * u * u * t * a + 3 * u * t * t * b + t * t * t;
  };
  let lo = 0;
  let hi = 1;
  let t = x;
  for (let i = 0; i < 24; i++) {
    const cx = coord(p[0], p[2], t);
    if (Math.abs(cx - x) < 0.0005) break;
    if (cx < x) lo = t;
    else hi = t;
    t = (lo + hi) / 2;
  }
  return coord(p[1], p[3], t);
}

/** CSS custom properties for the three springs at a pace (ThemeRoot inlines these). */
export function springCssVars(pace: Pace = "standard"): Record<string, string> {
  const vars: Record<string, string> = {};
  for (const name of Object.keys(springs) as SpringName[]) {
    const { easing, duration } = springEasing(springs[name], paceValue[pace]);
    vars[`--cc-spring-${name}`] = easing;
    vars[`--cc-spring-${name}-dur`] = `${Math.round(duration * 1000)}ms`;
  }
  return vars;
}

let currentPace: Pace = "standard";
export function setMotionPace(pace: Pace) {
  currentPace = pace;
}
const paced = (seconds: number) => (seconds * 1000) / paceValue[currentPace];

const reducedMotion = () =>
  typeof window !== "undefined" && window.matchMedia?.("(prefers-reduced-motion: reduce)").matches;

/**
 * WAAPI helpers — the web twins of CCMotion.spring/fade/run. They always
 * leave the element at the target (fill: "forwards" is committed then
 * cancelled) so later style writes are never fighting a held animation.
 */
export function animateSpring(
  el: Element,
  keyframes: Keyframe[],
  spring: SpringName = "smooth",
): Animation | null {
  if (reducedMotion()) {
    commitFinal(el, keyframes);
    return null;
  }
  const { easing, duration } = springEasing(springs[spring], paceValue[currentPace]);
  return finishInto(el, el.animate(keyframes, { duration: duration * 1000, easing, fill: "forwards" }));
}

export function animateCurve(
  el: Element,
  keyframes: Keyframe[],
  opts: { duration?: number; curve?: CubicBezier; delay?: number } = {},
): Animation | null {
  if (reducedMotion()) {
    commitFinal(el, keyframes);
    return null;
  }
  const anim = el.animate(keyframes, {
    duration: paced(opts.duration ?? durations.run),
    delay: opts.delay ? paced(opts.delay) : 0,
    easing: cssCurve(opts.curve ?? curves.settle),
    fill: "both",
  });
  return finishInto(el, anim);
}

function finishInto(_el: Element, anim: Animation): Animation {
  anim.addEventListener("finish", () => {
    try {
      anim.commitStyles();
    } catch {
      /* element detached */
    }
    anim.cancel();
  });
  return anim;
}

function commitFinal(el: Element, keyframes: Keyframe[]) {
  const last = keyframes[keyframes.length - 1];
  if (!last || !(el instanceof HTMLElement || el instanceof SVGElement)) return;
  for (const [k, v] of Object.entries(last)) {
    if (k === "offset" || k === "easing" || k === "composite" || v == null) continue;
    (el.style as unknown as Record<string, string>)[k] = String(v);
  }
}

/**
 * Drive a numeric value along a curve with rAF (the web twin of
 * CCMotion.animate(constraint:) — curve-true, retargetable, 1 write/frame).
 */
export function tween(
  from: number,
  to: number,
  onFrame: (value: number, done: boolean) => void,
  opts: { duration?: number; curve?: CubicBezier } = {},
): () => void {
  if (reducedMotion() || Math.abs(to - from) < 0.01) {
    onFrame(to, true);
    return () => {};
  }
  const total = paced(opts.duration ?? durations.grow);
  const curve = opts.curve ?? curves.bounce;
  const began = performance.now();
  let raf = 0;
  const tick = (now: number) => {
    const t = Math.min(1, (now - began) / total);
    const done = t >= 1;
    onFrame(done ? to : from + (to - from) * bezierY(t, curve), done);
    if (!done) raf = requestAnimationFrame(tick);
  };
  raf = requestAnimationFrame(tick);
  return () => cancelAnimationFrame(raf);
}
