import type { ReactNode } from "react";

/**
 * Original device frames for the light marketing pages, drawn as inline SVG.
 *
 * Each frame is three stacked layers inside a box that keeps the artwork's
 * aspect ratio, so the whole device scales with its container's width:
 *   1. the body (behind),
 *   2. the screen slot: any child (an <img>/<picture>, a <video>, or a live
 *      recreation), positioned in % of the same viewBox,
 *   3. the glass (in front): camera cut-out and a faint reflection.
 * Frame parts are decorative (`aria-hidden`); the screen child carries the
 * meaning, or the composition that uses the frames labels itself.
 */

// ── Phone ───────────────────────────────────────────────────────────────────
// viewBox 408 × 832: body x 4…404 (side keys hang off both edges), screen
// 368 × 800 inset 16 — the aspect of a 1206 × 2622 simulator capture.

const PHONE_W = 408;
const PHONE_H = 832;
const PHONE_SCREEN = { x: 20, y: 16, w: 368, h: 800 };

export function DevicePhone({ children, className = "" }: { children: ReactNode; className?: string }) {
  return (
    <div className={`air-device relative ${className}`} style={{ aspectRatio: `${PHONE_W} / ${PHONE_H}` }}>
      <svg className="absolute inset-0 h-full w-full" viewBox={`0 0 ${PHONE_W} ${PHONE_H}`} aria-hidden>
        <defs>
          <linearGradient id="airPhoneRim" x1="0" y1="0" x2="1" y2="1">
            <stop offset="0" stopColor="#6c6e75" />
            <stop offset="0.35" stopColor="#2c2d32" />
            <stop offset="0.7" stopColor="#3a3b41" />
            <stop offset="1" stopColor="#77797f" />
          </linearGradient>
          <linearGradient id="airPhoneKey" x1="0" y1="0" x2="1" y2="0">
            <stop offset="0" stopColor="#24252a" />
            <stop offset="1" stopColor="#5a5c62" />
          </linearGradient>
        </defs>
        {/* Side keys: action + volume on the left, side key on the right. */}
        <rect x="0.5" y="150" width="5" height="40" rx="2.5" fill="url(#airPhoneKey)" />
        <rect x="0.5" y="214" width="5" height="64" rx="2.5" fill="url(#airPhoneKey)" />
        <rect x="0.5" y="292" width="5" height="64" rx="2.5" fill="url(#airPhoneKey)" />
        <rect x="402.5" y="246" width="5" height="96" rx="2.5" fill="url(#airPhoneKey)" />
        {/* Body: a thin metal band, then the black glass bezel. */}
        <rect x="4" y="0" width="400" height="832" rx="66" fill="url(#airPhoneRim)" />
        <rect x="6.5" y="2.5" width="395" height="827" rx="63.5" fill="none" stroke="rgb(255 255 255 / 0.22)" strokeWidth="1" />
        <rect x="9" y="5" width="390" height="822" rx="61" fill="#060607" />
      </svg>
      <div
        className="air-device-screen absolute overflow-hidden bg-black"
        style={{
          left: pct(PHONE_SCREEN.x, PHONE_W),
          top: pct(PHONE_SCREEN.y, PHONE_H),
          width: pct(PHONE_SCREEN.w, PHONE_W),
          height: pct(PHONE_SCREEN.h, PHONE_H),
          // 52 / 368 of the width, 52 / 800 of the height: a circular corner.
          borderRadius: `${pct(52, PHONE_SCREEN.w)} / ${pct(52, PHONE_SCREEN.h)}`,
        }}
      >
        {children}
      </div>
      <svg className="pointer-events-none absolute inset-0 h-full w-full" viewBox={`0 0 ${PHONE_W} ${PHONE_H}`} aria-hidden>
        <defs>
          <linearGradient id="airPhoneGlare" x1="0" y1="0" x2="1" y2="1">
            <stop offset="0" stopColor="#fff" stopOpacity="0.1" />
            <stop offset="0.42" stopColor="#fff" stopOpacity="0" />
          </linearGradient>
        </defs>
        <rect x="20" y="16" width="368" height="800" rx="52" fill="url(#airPhoneGlare)" />
        {/* The pill-shaped camera cut-out. */}
        <rect x="147" y="27" width="114" height="34" rx="17" fill="#000" />
        <circle cx="243" cy="44" r="5.5" fill="#0d0f16" />
        <circle cx="241.8" cy="42.8" r="1.6" fill="#2a3350" />
      </svg>
    </div>
  );
}

// ── Laptop ──────────────────────────────────────────────────────────────────
// viewBox 1000 × 612: the lid (x 70…930) over a wider, low base. Screen
// 822 × 532 (≈ 1.55 : 1) sits in a thin black bezel with a camera notch.

const LAPTOP_W = 1000;
const LAPTOP_H = 612;
const LAPTOP_SCREEN = { x: 89, y: 23, w: 822, h: 532 };

export function DeviceLaptop({ children, className = "" }: { children: ReactNode; className?: string }) {
  return (
    <div className={`air-device relative ${className}`} style={{ aspectRatio: `${LAPTOP_W} / ${LAPTOP_H}` }}>
      {/* A soft lift under the lid, kept off the screen so the live content
          inside never repaints through a filter. */}
      <span aria-hidden className="air-laptop-lift" />
      <svg className="absolute inset-0 h-full w-full" viewBox={`0 0 ${LAPTOP_W} ${LAPTOP_H}`} aria-hidden>
        <defs>
          <linearGradient id="airLaptopRim" x1="0" y1="0" x2="0" y2="1">
            <stop offset="0" stopColor="#e9eaee" />
            <stop offset="1" stopColor="#b9bcc3" />
          </linearGradient>
          <linearGradient id="airLaptopHinge" x1="0" y1="0" x2="0" y2="1">
            <stop offset="0" stopColor="#1d1e22" />
            <stop offset="1" stopColor="#5d6067" />
          </linearGradient>
          <linearGradient id="airLaptopBase" x1="0" y1="0" x2="0" y2="1">
            <stop offset="0" stopColor="#f4f5f7" />
            <stop offset="0.45" stopColor="#d9dbe0" />
            <stop offset="1" stopColor="#9da0a8" />
          </linearGradient>
          <linearGradient id="airLaptopNotch" x1="0" y1="0" x2="1" y2="0">
            <stop offset="0" stopColor="#8d9097" />
            <stop offset="0.5" stopColor="#c9cbd1" />
            <stop offset="1" stopColor="#8d9097" />
          </linearGradient>
        </defs>
        {/* Lid: a silver rim around the black glass. */}
        <path d="M94 4H906A24 24 0 0 1 930 28V578A4 4 0 0 1 926 582H74A4 4 0 0 1 70 578V28A24 24 0 0 1 94 4Z" fill="url(#airLaptopRim)" />
        <path d="M95.5 6.5H904.5A22 22 0 0 1 926.5 28.5V579H73.5V28.5A22 22 0 0 1 95.5 6.5Z" fill="#070708" />
        {/* Hinge, then the base with its thumb notch and a lit front edge. */}
        <rect x="84" y="579" width="832" height="10" rx="2" fill="url(#airLaptopHinge)" />
        <path d="M0 587H1000V595C1000 602 993 606 982 606H18C7 606 0 602 0 595Z" fill="url(#airLaptopBase)" />
        <path d="M0 587H1000" stroke="#fff" strokeOpacity="0.9" strokeWidth="1.2" />
        <path d="M428 587H572V589.5C572 592.5 569.5 594 566 594H434C430.5 594 428 592.5 428 589.5Z" fill="url(#airLaptopNotch)" />
        <path d="M24 606H976" stroke="#6b6e75" strokeOpacity="0.55" strokeWidth="1" />
      </svg>
      <div
        className="air-device-screen absolute overflow-hidden bg-[#0e0e10]"
        style={{
          left: pct(LAPTOP_SCREEN.x, LAPTOP_W),
          top: pct(LAPTOP_SCREEN.y, LAPTOP_H),
          width: pct(LAPTOP_SCREEN.w, LAPTOP_W),
          height: pct(LAPTOP_SCREEN.h, LAPTOP_H),
          borderTopLeftRadius: `${pct(9, LAPTOP_SCREEN.w)} ${pct(9, LAPTOP_SCREEN.h)}`,
          borderTopRightRadius: `${pct(9, LAPTOP_SCREEN.w)} ${pct(9, LAPTOP_SCREEN.h)}`,
        }}
      >
        {children}
      </div>
      <svg className="pointer-events-none absolute inset-0 h-full w-full" viewBox={`0 0 ${LAPTOP_W} ${LAPTOP_H}`} aria-hidden>
        <defs>
          <linearGradient id="airLaptopGlare" x1="0" y1="0" x2="1" y2="1">
            <stop offset="0" stopColor="#fff" stopOpacity="0.07" />
            <stop offset="0.38" stopColor="#fff" stopOpacity="0" />
          </linearGradient>
        </defs>
        <rect x="89" y="23" width="822" height="532" fill="url(#airLaptopGlare)" />
        {/* Camera notch dropping from the top bezel. */}
        <path d="M447 22H553V31A8 8 0 0 1 545 39H455A8 8 0 0 1 447 31Z" fill="#070708" />
        <circle cx="500" cy="29.5" r="3.2" fill="#10131b" />
        <circle cx="499.3" cy="28.8" r="1" fill="#2c3550" />
      </svg>
    </div>
  );
}

// ── Tablet (landscape) ──────────────────────────────────────────────────────
// viewBox 1000 × 702: a slim metal band and an even black bezel around a
// 960 × 662 screen (the 1210 × 834 pt aspect of an 11-inch tablet held
// sideways); the front camera sits on the top long edge.

const TABLET_W = 1000;
const TABLET_H = 702;
const TABLET_SCREEN = { x: 20, y: 20, w: 960, h: 662 };

export function DeviceTablet({ children, className = "" }: { children: ReactNode; className?: string }) {
  return (
    <div className={`air-device relative ${className}`} style={{ aspectRatio: `${TABLET_W} / ${TABLET_H}` }}>
      <svg className="absolute inset-0 h-full w-full" viewBox={`0 0 ${TABLET_W} ${TABLET_H}`} aria-hidden>
        <defs>
          <linearGradient id="airTabletRim" x1="0" y1="0" x2="1" y2="1">
            <stop offset="0" stopColor="#d9dbe0" />
            <stop offset="0.5" stopColor="#a7aab2" />
            <stop offset="1" stopColor="#d2d4d9" />
          </linearGradient>
        </defs>
        {/* Top keys on the band. */}
        <rect x="770" y="0" width="64" height="5" rx="2.5" fill="#9b9ea6" />
        <rect x="850" y="0" width="64" height="5" rx="2.5" fill="#9b9ea6" />
        <rect x="0" y="2" width="1000" height="700" rx="46" fill="url(#airTabletRim)" />
        <rect x="2.5" y="4.5" width="995" height="695" rx="43.5" fill="none" stroke="rgb(255 255 255 / 0.55)" strokeWidth="1" />
        <rect x="4" y="6" width="992" height="692" rx="42" fill="#060607" />
      </svg>
      <div
        className="air-device-screen absolute overflow-hidden bg-black"
        style={{
          left: pct(TABLET_SCREEN.x, TABLET_W),
          top: pct(TABLET_SCREEN.y, TABLET_H),
          width: pct(TABLET_SCREEN.w, TABLET_W),
          height: pct(TABLET_SCREEN.h, TABLET_H),
          borderRadius: `${pct(24, TABLET_SCREEN.w)} / ${pct(24, TABLET_SCREEN.h)}`,
        }}
      >
        {children}
      </div>
      <svg className="pointer-events-none absolute inset-0 h-full w-full" viewBox={`0 0 ${TABLET_W} ${TABLET_H}`} aria-hidden>
        <defs>
          <linearGradient id="airTabletGlare" x1="0" y1="0" x2="1" y2="1">
            <stop offset="0" stopColor="#fff" stopOpacity="0.08" />
            <stop offset="0.4" stopColor="#fff" stopOpacity="0" />
          </linearGradient>
        </defs>
        <rect x="20" y="20" width="960" height="662" rx="24" fill="url(#airTabletGlare)" />
        <circle cx="500" cy="13" r="3.6" fill="#10131b" />
        <circle cx="499.2" cy="12.2" r="1.1" fill="#2c3550" />
      </svg>
    </div>
  );
}

// ── Foldable, unfolded ──────────────────────────────────────────────────────
// viewBox 984 × 699: a slim frame around a 960 × 675 inner screen (the
// ≈ 951 × 669 pt aspect of the unfolded display), folding down the middle.
// The crease is drawn over the screen as a soft light-dark-light band, and
// the hinge shows as small breaks in the frame at the top and bottom.

const FOLD_W = 984;
const FOLD_H = 699;
const FOLD_SCREEN = { x: 12, y: 12, w: 960, h: 675 };

export function DeviceFoldable({ children, className = "" }: { children: ReactNode; className?: string }) {
  return (
    <div className={`air-device relative ${className}`} style={{ aspectRatio: `${FOLD_W} / ${FOLD_H}` }}>
      <svg className="absolute inset-0 h-full w-full" viewBox={`0 0 ${FOLD_W} ${FOLD_H}`} aria-hidden>
        <defs>
          <linearGradient id="airFoldRim" x1="0" y1="0" x2="1" y2="0">
            <stop offset="0" stopColor="#6c6e75" />
            <stop offset="0.49" stopColor="#2e2f34" />
            <stop offset="0.5" stopColor="#18191c" />
            <stop offset="0.51" stopColor="#2e2f34" />
            <stop offset="1" stopColor="#77797f" />
          </linearGradient>
        </defs>
        <rect x="0" y="0" width="984" height="699" rx="40" fill="url(#airFoldRim)" />
        <rect x="2" y="2" width="980" height="695" rx="38" fill="none" stroke="rgb(255 255 255 / 0.2)" strokeWidth="1" />
        <rect x="4" y="4" width="976" height="691" rx="36" fill="#060607" />
        {/* Hinge breaks in the frame. */}
        <rect x="488" y="0" width="8" height="4" fill="#0b0b0d" />
        <rect x="488" y="695" width="8" height="4" fill="#0b0b0d" />
      </svg>
      <div
        className="air-device-screen absolute overflow-hidden bg-black"
        style={{
          left: pct(FOLD_SCREEN.x, FOLD_W),
          top: pct(FOLD_SCREEN.y, FOLD_H),
          width: pct(FOLD_SCREEN.w, FOLD_W),
          height: pct(FOLD_SCREEN.h, FOLD_H),
          borderRadius: `${pct(28, FOLD_SCREEN.w)} / ${pct(28, FOLD_SCREEN.h)}`,
        }}
      >
        {children}
      </div>
      <svg className="pointer-events-none absolute inset-0 h-full w-full" viewBox={`0 0 ${FOLD_W} ${FOLD_H}`} aria-hidden>
        <defs>
          <linearGradient id="airFoldCrease" x1="0" y1="0" x2="1" y2="0">
            <stop offset="0" stopColor="#000" stopOpacity="0" />
            <stop offset="0.4" stopColor="#000" stopOpacity="0.16" />
            <stop offset="0.5" stopColor="#fff" stopOpacity="0.22" />
            <stop offset="0.6" stopColor="#000" stopOpacity="0.16" />
            <stop offset="1" stopColor="#000" stopOpacity="0" />
          </linearGradient>
          <linearGradient id="airFoldShade" x1="0" y1="0" x2="1" y2="0">
            <stop offset="0" stopColor="#fff" stopOpacity="0.06" />
            <stop offset="0.5" stopColor="#000" stopOpacity="0.07" />
            <stop offset="1" stopColor="#fff" stopOpacity="0.02" />
          </linearGradient>
        </defs>
        <rect x="12" y="12" width="960" height="675" rx="28" fill="url(#airFoldShade)" />
        <rect x="474" y="12" width="36" height="675" fill="url(#airFoldCrease)" />
        {/* Inner camera, top corner of the right half. */}
        <circle cx="936" cy="34" r="6" fill="#050608" />
        <circle cx="934.8" cy="32.8" r="1.7" fill="#2a3350" />
      </svg>
    </div>
  );
}

function pct(part: number, whole: number) {
  return `${((part / whole) * 100).toFixed(4)}%`;
}

// ── The lineup: every device CaptureCat runs on, as one product shot ────────

/**
 * Product shot: the laptop large at the back, the tablet stepping in from
 * the left, the unfolded foldable and the phone in front on the right.
 * Geometry lives in airy.css (`.air-lineup*`) so the overlaps hold at every
 * width; on narrow screens the tablet and the foldable tuck in behind and
 * the phone grows, so nothing shrinks past reading.
 */
export function DeviceLineup({
  laptopScreen,
  tabletScreen,
  foldableScreen,
  phoneScreen,
  label,
  className = "",
}: {
  laptopScreen: ReactNode;
  tabletScreen: ReactNode;
  foldableScreen: ReactNode;
  phoneScreen: ReactNode;
  /** What the composition shows, for assistive tech. */
  label: string;
  className?: string;
}) {
  return (
    <div role="img" aria-label={label} className={`air-lineup ${className}`}>
      <span aria-hidden className="air-lineup-floor" />
      <div className="air-lineup-laptop">
        <DeviceLaptop>{laptopScreen}</DeviceLaptop>
      </div>
      <div className="air-lineup-tablet">
        <DeviceTablet>{tabletScreen}</DeviceTablet>
      </div>
      <div className="air-lineup-fold">
        <DeviceFoldable>{foldableScreen}</DeviceFoldable>
      </div>
      <div className="air-lineup-phone">
        <DevicePhone>{phoneScreen}</DevicePhone>
      </div>
    </div>
  );
}
