import type { ReactNode } from "react";

/**
 * Original Mac-style app icons for the hero's dock: the rounded-square
 * "squircle" shape, layered gradients, a soft top highlight and a drop
 * shadow, like a desktop dock — but every motif is our own drawing (a folder
 * with a front flap, an orbiting planet, two bubbles, a ringed notepad, a
 * record, sliders, a frosted bin). No real app's icon is reproduced. Each
 * icon is a 100 × 100 SVG; ids are prefixed per icon so several can share a
 * page.
 */

/** A continuous-corner squircle filling the 100 × 100 icon body. */
const SQUIRCLE = "M50 3C86 3 97 14 97 50S86 97 50 97 3 86 3 50 14 3 50 3Z";

function Icon({ id, children, base }: { id: string; children: ReactNode; base: [string, string] }) {
  return (
    <svg viewBox="0 0 100 100" aria-hidden focusable="false">
      <defs>
        <linearGradient id={`${id}-bg`} x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stopColor={base[0]} />
          <stop offset="1" stopColor={base[1]} />
        </linearGradient>
        <linearGradient id={`${id}-gloss`} x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stopColor="#fff" stopOpacity="0.42" />
          <stop offset="0.5" stopColor="#fff" stopOpacity="0" />
        </linearGradient>
        <clipPath id={`${id}-clip`}>
          <path d={SQUIRCLE} />
        </clipPath>
      </defs>
      <path d={SQUIRCLE} fill={`url(#${id}-bg)`} />
      <g clipPath={`url(#${id}-clip)`}>{children}</g>
      <path d={SQUIRCLE} fill={`url(#${id}-gloss)`} />
      <path d={SQUIRCLE} fill="none" stroke="#fff" strokeOpacity="0.28" strokeWidth="1" />
    </svg>
  );
}

export function FilesIcon() {
  return (
    <Icon id="dk-files" base={["#e9f4ff", "#c9e2fb"]}>
      <defs>
        <linearGradient id="dk-files-back" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stopColor="#4aa8ff" />
          <stop offset="1" stopColor="#1f7ae6" />
        </linearGradient>
        <linearGradient id="dk-files-front" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stopColor="#7cc4ff" />
          <stop offset="1" stopColor="#3b95f5" />
        </linearGradient>
      </defs>
      <path d="M18 30a6 6 0 0 1 6-6h17l6 7h29a6 6 0 0 1 6 6v37a6 6 0 0 1-6 6H24a6 6 0 0 1-6-6Z" fill="url(#dk-files-back)" />
      <path d="M16 42a6 6 0 0 1 6-6h56a6 6 0 0 1 6 6l-3 32a6 6 0 0 1-6 6H25a6 6 0 0 1-6-6Z" fill="url(#dk-files-front)" />
      <path d="M17 42a6 6 0 0 1 6-6h54" stroke="#fff" strokeOpacity="0.6" strokeWidth="1.5" fill="none" />
    </Icon>
  );
}

export function BrowserIcon() {
  return (
    <Icon id="dk-web" base={["#ffffff", "#e6e9f2"]}>
      <defs>
        <radialGradient id="dk-web-planet" cx="0.38" cy="0.32" r="0.75">
          <stop offset="0" stopColor="#9ee7ff" />
          <stop offset="0.55" stopColor="#3f8cff" />
          <stop offset="1" stopColor="#3a37c9" />
        </radialGradient>
      </defs>
      <ellipse cx="50" cy="52" rx="38" ry="12" fill="none" stroke="#f6a54a" strokeWidth="5" transform="rotate(-18 50 52)" strokeDasharray="120 200" strokeDashoffset="-58" />
      <circle cx="50" cy="51" r="25" fill="url(#dk-web-planet)" />
      <path d="M31 44c8 4 19 1 26-5M33 60c9-2 18 4 30-2" stroke="#fff" strokeOpacity="0.45" strokeWidth="3" strokeLinecap="round" fill="none" />
      <ellipse cx="50" cy="52" rx="38" ry="12" fill="none" stroke="#ffbf5e" strokeWidth="5" transform="rotate(-18 50 52)" strokeDasharray="120 200" strokeDashoffset="62" />
    </Icon>
  );
}

export function ChatIcon() {
  return (
    <Icon id="dk-chat" base={["#7ef0c1", "#1fb57e"]}>
      <path d="M24 26h36a10 10 0 0 1 10 10v14a10 10 0 0 1-10 10H40l-12 9v-9h-4a10 10 0 0 1-10-10V36a10 10 0 0 1 10-10Z" fill="#fff" fillOpacity="0.55" />
      <path d="M44 40h32a10 10 0 0 1 10 10v12a10 10 0 0 1-10 10h-2v8l-11-8H44a10 10 0 0 1-10-10V50a10 10 0 0 1 10-10Z" fill="#fff" />
      <circle cx="49" cy="56" r="3" fill="#1fb57e" />
      <circle cx="60" cy="56" r="3" fill="#1fb57e" />
      <circle cx="71" cy="56" r="3" fill="#1fb57e" />
    </Icon>
  );
}

export function NotesIcon() {
  return (
    <Icon id="dk-notes" base={["#ffb25c", "#f2731f"]}>
      <rect x="24" y="20" width="52" height="64" rx="7" fill="#fffaf0" />
      <rect x="24" y="20" width="52" height="14" rx="7" fill="#ffe3a3" />
      <rect x="24" y="27" width="52" height="7" fill="#ffe3a3" />
      {[34, 44, 54, 64].map((x) => (
        <rect key={x} x={x - 2} y="15" width="4" height="12" rx="2" fill="#8a8f9c" />
      ))}
      {[44, 53, 62, 71].map((y, i) => (
        <rect key={y} x="32" y={y} width={i === 3 ? 22 : 36} height="3" rx="1.5" fill="#d8cfbd" />
      ))}
    </Icon>
  );
}

export function MusicIcon() {
  return (
    <Icon id="dk-music" base={["#ff8a9a", "#e8365f"]}>
      <defs>
        <radialGradient id="dk-music-disc" cx="0.4" cy="0.35" r="0.7">
          <stop offset="0" stopColor="#3b3550" />
          <stop offset="1" stopColor="#141221" />
        </radialGradient>
      </defs>
      <circle cx="50" cy="50" r="31" fill="url(#dk-music-disc)" />
      <circle cx="50" cy="50" r="24" fill="none" stroke="#fff" strokeOpacity="0.08" strokeWidth="1.5" />
      <circle cx="50" cy="50" r="18" fill="none" stroke="#fff" strokeOpacity="0.08" strokeWidth="1.5" />
      <path d="M30 34a28 28 0 0 1 22-12" stroke="#fff" strokeOpacity="0.35" strokeWidth="2.5" strokeLinecap="round" fill="none" />
      <circle cx="50" cy="50" r="10" fill="#ffd36e" />
      <circle cx="50" cy="50" r="2.6" fill="#141221" />
    </Icon>
  );
}

export function SettingsIcon() {
  return (
    <Icon id="dk-set" base={["#c9ccd6", "#7d818e"]}>
      {[34, 50, 66].map((x, i) => (
        <g key={x}>
          <rect x={x - 2.5} y="24" width="5" height="52" rx="2.5" fill="#3e4250" fillOpacity="0.55" />
          <circle cx={x} cy={[40, 60, 34][i]} r="7.5" fill="#fff" />
          <circle cx={x} cy={[40, 60, 34][i]} r="7.5" fill="none" stroke="#3e4250" strokeOpacity="0.25" strokeWidth="1.5" />
        </g>
      ))}
    </Icon>
  );
}

/** The bin at the dock's end: frosted glass with ribs. */
export function BinIcon() {
  return (
    <svg viewBox="0 0 100 100" aria-hidden focusable="false">
      <defs>
        <linearGradient id="dk-bin" x1="0" y1="0" x2="1" y2="0">
          <stop offset="0" stopColor="#ffffff" stopOpacity="0.55" />
          <stop offset="0.5" stopColor="#ffffff" stopOpacity="0.85" />
          <stop offset="1" stopColor="#ffffff" stopOpacity="0.5" />
        </linearGradient>
      </defs>
      <path d="M26 28h48l-5 58a6 6 0 0 1-6 5H37a6 6 0 0 1-6-5Z" fill="url(#dk-bin)" stroke="#fff" strokeOpacity="0.9" strokeWidth="1.5" />
      <rect x="22" y="20" width="56" height="9" rx="4.5" fill="#fff" fillOpacity="0.9" />
      {[40, 50, 60].map((x) => (
        <path key={x} d={`M${x} 38v42`} stroke="#9aa0b4" strokeOpacity="0.55" strokeWidth="2.5" strokeLinecap="round" />
      ))}
    </svg>
  );
}
