/**
 * The Mac recording panel (RecordingPanelViewController) on a desktop:
 *
 *   setup  [Display|Window|Area|iPhone|URL] | [Studio Display ▾] | [Mic · Cam ▮▮▮▮ ▾] [Audio On] [⚙] [●]
 *   live   [● 0:03] [Studio Display] [❚❚] [⇄] [↺] [■] [🗑]
 *
 * The 3·2·1 is the CountdownOverlayController dial centred on the screen
 * being captured; the panel stays in setup while it runs, then morphs to the
 * live row (RecordingMotion: 0.45 s resize, rows crossfade out/in by halves).
 */
import type { ReactNode } from "react";
import {
  AppWindow,
  ArrowLeftRight,
  ChevronDown,
  CircleDot,
  Link2,
  Monitor,
  Pause,
  RotateCcw,
  Settings,
  SlidersHorizontal,
  Smartphone,
  Square,
  SquareDashed,
  Trash2,
  Volume2,
} from "lucide-react";

import { AppleGlyph } from "../../primitives";
import { Card, Cursor } from "./parts";

const TABS = [
  { label: "Display", Icon: Monitor },
  { label: "Window", Icon: AppWindow },
  { label: "Area", Icon: SquareDashed },
  { label: "iPhone", Icon: Smartphone },
  { label: "URL", Icon: Link2 },
];

export function Meter() {
  return (
    <span className="ccd-meter">
      <i />
      <i />
      <i />
      <i />
    </span>
  );
}

export function MacRecordingBar() {
  return (
    <div className="ccd-rec">
      <span className="ccd-rec-cap ccd-rec-cap--l" />
      <span className="ccd-rec-mid" />
      <span className="ccd-rec-cap ccd-rec-cap--r" />

      <div className="ccd-rec-row ccd-rec-setup">
        <div className="ccd-rec-tabs">
          <span className="ccd-rec-pill" />
          {TABS.map(({ label, Icon }, i) => (
            <span key={label} className={`ccd-rec-tab ${i === 0 ? "is-on" : ""}`}>
              <Icon strokeWidth={1.6} />
              {label}
            </span>
          ))}
        </div>
        <span className="ccd-rec-div" />
        <span className="ccd-rec-key" style={{ flex: 1, justifyContent: "flex-start" }}>
          <Monitor className="ccd-dim" />
          Studio Display
          <ChevronDown className="ccd-dim" style={{ marginLeft: "auto" }} />
        </span>
        <span className="ccd-rec-div" />
        <span className="ccd-rec-key">
          <SlidersHorizontal className="ccd-dim" />
          <Meter />
          Mic · Cam
          <ChevronDown className="ccd-dim" />
        </span>
        <span className="ccd-rec-key">
          <Volume2 className="ccd-dim" />
          Audio On
        </span>
        <span className="ccd-rec-key">
          <Settings className="ccd-dim" />
        </span>
        <span className="ccd-rec-record">
          <CircleDot strokeWidth={2.2} />
          <span className="ccd-rec-tint" />
        </span>
      </div>

      <div className="ccd-rec-row ccd-rec-live">
        <span className="ccd-rec-timer">
          <span className="ccd-rec-dot" />
          <span>
            0:0
            <span className="ccd-digits">
              <span>
                <span>0</span>
                <span>1</span>
                <span>2</span>
                <span>3</span>
              </span>
            </span>
          </span>
        </span>
        <span className="ccd-rec-key" style={{ flex: 1, color: "rgb(255 255 255 / 0.55)" }}>
          <Monitor />
          Studio Display
        </span>
        <span className="ccd-rec-key" style={{ width: "calc(36 * var(--u))", padding: 0 }}>
          <Pause fill="currentColor" />
        </span>
        <span className="ccd-rec-key" style={{ width: "calc(36 * var(--u))", padding: 0 }}>
          <ArrowLeftRight />
        </span>
        <span className="ccd-rec-key" style={{ width: "calc(36 * var(--u))", padding: 0 }}>
          <RotateCcw />
        </span>
        <span className="ccd-rec-key ccd-rec-stop" style={{ width: "calc(36 * var(--u))", padding: 0, overflow: "hidden" }}>
          <Square fill="currentColor" />
          <span className="ccd-rec-tint" />
        </span>
        <span className="ccd-rec-key ccd-rec-stop" style={{ width: "calc(36 * var(--u))", padding: 0 }}>
          <Trash2 />
        </span>
      </div>
    </div>
  );
}

export function CountdownDial() {
  return (
    <div className="ccd-dial">
      <div className="ccd-dial-ring">
        <div className="ccd-dial-half ccd-dial-half--r">
          <div className="ccd-dial-cover" />
        </div>
        <div className="ccd-dial-half ccd-dial-half--l">
          <div className="ccd-dial-cover" />
        </div>
      </div>
      <div className="ccd-dial-face">
        <span className="ccd-dial-num">3</span>
        <span className="ccd-dial-num">2</span>
        <span className="ccd-dial-num">1</span>
      </div>
    </div>
  );
}

export function MenuBar({ children }: { children?: ReactNode }) {
  return (
    <div className="ccd-menubar">
      <AppleGlyph className="ccd-apple" />
      <b>Projects</b>
      <span>File</span>
      <span>Edit</span>
      <span>View</span>
      <span>Window</span>
      <span className="ccd-menubar-r">
        {children}
        Tue 9:41
      </span>
    </div>
  );
}

/** Scene: a desktop with the app window, the panel docked at the bottom. */
export function RecordingDesktop() {
  return (
    <>
      <div className="ccd-desk" />
      <MenuBar />
      <div className="ccd-win">
        <Card />
      </div>
      <CountdownDial />
      <MacRecordingBar />
      <span className="ccd-scene-track">
        <Cursor />
      </span>
    </>
  );
}
