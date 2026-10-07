/**
 * Stage scenes shared by the pinned stories on the home, features, and
 * download pages. Each scene is static markup; its loop runs while the scene
 * carries `data-active` (usePinnedSteps), styled in styles/demos.css.
 */
import type { ReactNode } from "react";
import { Camera, ChevronDown, Link2, Monitor, Settings, Search } from "lucide-react";

import { Canvas, Cursor, KeysPill } from "./parts";
import { MacRecordingBar, MenuBar } from "./RecordingScene";

// ── Export sheet → share link (ExportSheetController) ─────────────────────

/** `bucket`: the share uploads to the user's own storage (features page). */
export function ExportScene({ quality = false, bucket }: { quality?: boolean; bucket?: string }) {
  return (
    <>
      <Canvas script="export" className="ccd-canvas--cover" />
      <div className="ccd-sheet-scrim" />
      <div className={`ccd-sheet ${quality ? "ccd-sheet--q" : ""}`}>
        <h5>Export</h5>
        <div className="ccd-sheet-body">
          <div className="ccd-sheet-form">
            <div className="ccd-sheet-row">
              Format
              <div className="ccd-seg">
                <span>MP4</span>
                <span>MOV</span>
                <span>GIF</span>
              </div>
            </div>
            <div className="ccd-sheet-row">
              Resolution
              <div className="ccd-seg" data-sel="1">
                <span>1080p</span>
                <span>4K</span>
                <span>Custom</span>
              </div>
            </div>
            <div className="ccd-sheet-row">
              Frame rate
              <div className="ccd-seg" data-n="2" data-sel="1">
                <span>30 fps</span>
                <span>60 fps</span>
              </div>
            </div>
            {quality ? (
              <>
                <div className="ccd-sheet-row">
                  Quality
                  <div className="ccd-slider ccd-sheet-slider">
                    <span className="ccd-slider-track" />
                    <span className="ccd-slider-thumb ccd-thumb-q" />
                  </div>
                </div>
                <div className="ccd-sheet-cap">
                  <span className="ccd-cap-a">High • 3840×2160 @ 60 fps • ~31 Mbps</span>
                  <span className="ccd-cap-b">Master • 3840×2160 @ 60 fps • ~62 Mbps</span>
                </div>
                <div className="ccd-sheet-row">
                  Fast export (collapse still frames)
                  <span className="ccd-sheet-toggle" />
                </div>
              </>
            ) : (
              <div className="ccd-sheet-row">
                Share link after export
                <span className="ccd-sheet-toggle" />
              </div>
            )}
            <div className="ccd-sheet-foot">
              <span className="ccd-key">Cancel</span>
              <span className="ccd-key ccd-key--primary">
                Export
                <span className="ccd-rec-tint" />
              </span>
            </div>
          </div>
          <div className="ccd-sheet-progress">
            Exporting…
            <span className="ccd-bar">
              <i />
            </span>
            <span className="ccd-sheet-sub ccd-sub-a">4K · 60 fps · MP4</span>
            <span className="ccd-sheet-sub ccd-sub-b">{quality ? "Saved to Movies" : bucket ? `Uploading to ${bucket}` : "Uploading to capturecat.so"}</span>
          </div>
        </div>
      </div>
      {!quality && (
        <div className="ccd-link">
          <b>capturecat.so/share/7Kq2fX</b>
          <em>{bucket ? `Plays from ${bucket}` : "Anyone with the link"}</em>
          <span>✓ Copied</span>
        </div>
      )}
    </>
  );
}

// ── Features page ───────────────────────────────────────────────────────────

/** An iPhone with Dynamic Island on a wallpaper, tap indicators looping. */
export function IPhoneScene() {
  return (
    <>
      <div className="ccd-wall" />
      <div className="ccd-phone-cam">
        <div className="ccd-phone">
          <span className="ccd-phone-btn ccd-phone-btn--a" />
          <span className="ccd-phone-btn ccd-phone-btn--b" />
          <span className="ccd-phone-btn ccd-phone-btn--c" />
          <div className="ccd-phone-screen">
            <div className="ccd-ios-status">
              <b>9:41</b>
              <span>
                <i />
                <i />
                <i />
              </span>
            </div>
            <div className="ccd-ios-island" />
            <div className="ccd-ios-body">
              <div className="ccd-ios-title">Projects</div>
              {["Launch video", "Onboarding tour", "Release notes"].map((t, i) => (
                <div key={t} className="ccd-ios-card">
                  <i data-i={i} />
                  <span>
                    <b>{t}</b>
                    <small>{["Edited today", "2 days ago", "Last week"][i]}</small>
                  </span>
                </div>
              ))}
              <div className="ccd-ios-btn">New project</div>
            </div>
            <span className="ccd-tap ccd-tap-1" />
            <span className="ccd-tap ccd-tap-2" />
          </div>
        </div>
      </div>
    </>
  );
}

/** URL capture: the panel's URL tab, then the full-height page it produced. */
export function WebCaptureScene() {
  return (
    <>
      <div className="ccd-desk ccd-desk--dim" />
      <div className="ccd-urlpanel">
        <span className="ccd-rec-key ccd-urlfield">
          <Link2 className="ccd-dim" />
          https://acme.dev/pricing
        </span>
        <span className="ccd-rec-key">
          <Monitor className="ccd-dim" />
          Desktop
          <ChevronDown className="ccd-dim" />
        </span>
        <span className="ccd-rec-key">
          <Settings className="ccd-dim" />
        </span>
        <span className="ccd-rec-record ccd-rec-shot">
          <Camera strokeWidth={2} />
          <span className="ccd-rec-tint" />
        </span>
      </div>
      <div className="ccd-pageshot">
        <div className="ccd-page">
          <div className="ccd-page-nav">
            <b>acme</b>
            <span />
            <span />
            <span />
            <i />
          </div>
          <div className="ccd-page-hero">
            <b>Pricing that grows with you</b>
            <span />
            <span />
          </div>
          <div className="ccd-page-cols">
            {[0, 1, 2].map((i) => (
              <div key={i} data-hi={i === 1 ? "" : undefined}>
                <b />
                <i />
                <span />
                <span />
                <span />
                <em />
              </div>
            ))}
          </div>
          <div className="ccd-page-faq">
            {[0, 1, 2, 3, 4].map((i) => (
              <span key={i} />
            ))}
          </div>
          <div className="ccd-page-foot" />
        </div>
        <div className="ccd-page-cookie">
          We use cookies to improve your experience. <b>Accept all</b>
        </div>
        <div className="ccd-page-chat">?</div>
        <div className="ccd-page-flash" />
      </div>
    </>
  );
}

/** Annotations building in over the recording. */
export function AnnotationsScene() {
  return (
    <Canvas script="annot" className="">
      <div className="ccd-spot ccd-spot--name" />
      <div className="ccd-ann-title">Create your first project</div>
      <svg className="ccd-ann-arrow" viewBox="0 0 960 540" aria-hidden>
        <path d="M232 118 C 250 170, 270 190, 312 200" fill="none" stroke="#ffd60a" strokeWidth="5" strokeLinecap="round" />
        <path d="M296 186 L316 201 L294 212" fill="none" stroke="#ffd60a" strokeWidth="5" strokeLinecap="round" strokeLinejoin="round" />
      </svg>
      <div className="ccd-ann-callout">Name it here</div>
      <svg className="ccd-ann-ring" viewBox="0 0 960 540" aria-hidden>
        <path d="M322 350 C 330 330, 470 326, 482 348 C 494 372, 420 392, 350 386 C 300 380, 306 356, 336 344" fill="none" stroke="#ff453a" strokeWidth="4" strokeLinecap="round" />
      </svg>
      <span className="ccd-ann-tap" />
      <span className="ccd-ann-tap ccd-ann-tap--2" />
    </Canvas>
  );
}

/** The keystroke overlay, one shortcut at a time. */
export function KeystrokesScene() {
  return (
    <Canvas script="keys">
      <div className="ccd-keyseq">
        <KeysPill keys={["⌘", "⇧", "S"]} />
        <KeysPill keys={["⌘", "K"]} />
        <KeysPill keys={["⌘", "B"]} />
        <KeysPill keys={["⌥", "⌘", "N"]} />
      </div>
    </Canvas>
  );
}

const LIB = [
  { t: "Billing walkthrough", d: "1:36" },
  { t: "Onboarding tour", d: "0:52" },
  { t: "Settings deep dive", d: "2:14" },
  { t: "Invoice export bug", d: "0:38" },
  { t: "Launch video", d: "0:12" },
  { t: "Team roles", d: "1:05" },
];

/** Library with ⌘K search over the text inside recordings (on-device OCR). */
export function LibraryScene() {
  return (
    <>
      <div className="ccd-lib">
        <div className="ccd-lib-side">
          <b>Library</b>
          <span className="is-on">All Captures</span>
          <span>Recent</span>
          <span>Pinned</span>
          <b>Folders</b>
          <span>Launches</span>
          <span>Support</span>
        </div>
        <div className="ccd-lib-grid">
          {LIB.map((c, i) => (
            <div key={c.t} className="ccd-lib-item">
              <div className="ccd-lib-thumb" data-i={i % 3}>
                <em>{c.d}</em>
              </div>
              <span>{c.t}</span>
            </div>
          ))}
        </div>
      </div>
      <div className="ccd-palette">
        <div className="ccd-palette-field">
          <Search className="ccd-dim" />
          <span className="ccd-palette-q">
            {Array.from("invoice").map((ch, i) => (
              <span key={i} className="ccd-qch" style={{ animationDelay: `${0.6 + i * 0.1}s` }}>
                {ch}
              </span>
            ))}
          </span>
        </div>
        <div className="ccd-palette-list">
          <span className="ccd-palette-sel" />
          {[
            ["Billing walkthrough", "0:42", "", "Invoice", " #1042 · Paid"],
            ["Invoice export bug", "0:07", "Export ", "invoice", " as PDF"],
            ["Settings deep dive", "1:31", "", "Invoice", " email address"],
          ].map(([t, at, pre, hit, post], i) => (
            <div key={t} className="ccd-palette-row" style={{ animationDelay: `${1.4 + i * 0.12}s` }}>
              <i data-i={i} />
              <span>
                <b>{t}</b>
                <small>
                  {at} · “{pre}
                  <mark>{hit}</mark>
                  {post}”
                </small>
              </span>
            </div>
          ))}
        </div>
      </div>
      <div className="ccd-jump">
        <div className="ccd-jump-frame">
          <div className="ccd-jump-doc">
            <b>Invoice #1042</b>
            <span />
            <span />
            <span />
            <em>Paid</em>
          </div>
          <span className="ccd-jump-hit" />
        </div>
        <div className="ccd-jump-cap">Billing walkthrough · jumped to 0:42</div>
      </div>
    </>
  );
}

// ── Download page ─────────────────────────────────────────────────────────

/** The .dmg window: drag the app onto Applications. */
export function DmgScene() {
  return (
    <>
      <div className="ccd-desk" />
      <MenuBar />
      <div className="ccd-finder">
        <div className="ccd-finder-bar">
          <span className="ccd-lights">
            <i />
            <i />
            <i />
          </span>
          <b>CaptureCat</b>
        </div>
        <div className="ccd-finder-body">
          <div className="ccd-finder-app">
            <img src="/apple-icon.png" alt="" width={96} height={96} loading="lazy" decoding="async" />
            <span>CaptureCat</span>
          </div>
          <svg className="ccd-finder-arrow" viewBox="0 0 120 40" aria-hidden>
            <path d="M6 20 H100 M88 8 L104 20 L88 32" fill="none" stroke="rgb(255 255 255 / 0.35)" strokeWidth="5" strokeLinecap="round" strokeLinejoin="round" />
          </svg>
          <div className="ccd-finder-apps">
            <span className="ccd-folder">
              <span className="ccd-folder-hi" />
            </span>
            <span>Applications</span>
          </div>
          <img className="ccd-finder-ghost" src="/apple-icon.png" alt="" width={96} height={96} loading="lazy" decoding="async" />
        </div>
      </div>
      <span className="ccd-scene-track ccd-dmg-cursor">
        <Cursor />
      </span>
    </>
  );
}

/** macOS asks for Screen Recording; the switch goes on in System Settings. */
export function PermissionScene() {
  return (
    <>
      <div className="ccd-desk" />
      <MenuBar />
      <div className="ccd-alert">
        <img src="/apple-icon.png" alt="" width={64} height={64} loading="lazy" decoding="async" />
        <b>“CaptureCat” would like to record this computer’s screen and audio.</b>
        <p>Grant access to this application in Privacy &amp; Security settings, located in System Settings.</p>
        <span className="ccd-alert-btn ccd-alert-btn--primary">
          Open System Settings
          <span className="ccd-rec-tint" />
        </span>
        <span className="ccd-alert-btn">Deny</span>
      </div>
      <div className="ccd-settings">
        <div className="ccd-settings-side">
          <span />
          <span />
          <span className="is-on" />
          <span />
          <span />
        </div>
        <div className="ccd-settings-main">
          <b>Screen &amp; System Audio Recording</b>
          <p>Allow the applications below to record the content of your screen and audio.</p>
          <div className="ccd-settings-list">
            {["CaptureCat", "Terminal", "QuickTime Player"].map((n, i) => (
              <div key={n} className="ccd-settings-row">
                <i data-i={i} />
                {n}
                <span className={`ccd-switch ${i === 0 ? "ccd-switch--live" : ""}`}>
                  <span className="ccd-switch-on" />
                  <span className="ccd-switch-knob" />
                </span>
              </div>
            ))}
          </div>
        </div>
      </div>
      <span className="ccd-scene-track ccd-perm-cursor">
        <Cursor />
      </span>
    </>
  );
}

/** The menu bar icon's menu, then the recording panel. */
export function MenuBarScene() {
  return (
    <>
      <div className="ccd-desk" />
      <MenuBar>
        <img className="ccd-menubar-icon" src="/apple-icon.png" alt="" width={16} height={16} loading="lazy" decoding="async" />
      </MenuBar>
      <div className="ccd-menu">
        {[
          ["New Recording...", "⌘N"],
          ["Browse Captures...", "⌘O"],
          null,
          ["Settings…", "⌘,"],
          ["Connect AI Agents...", ""],
          ["Check for Updates...", ""],
          null,
          ["Quit CaptureCat", "⌘Q"],
        ].map((item, i) =>
          item ? (
            <span key={i} className={`ccd-menu-item ${i === 0 ? "ccd-menu-item--hot" : ""}`}>
              {item[0]}
              <em>{item[1]}</em>
            </span>
          ) : (
            <i key={i} />
          ),
        )}
      </div>
      <div className="ccd-rec-rise">
        <MacRecordingBar />
      </div>
      <span className="ccd-scene-track ccd-menu-cursor">
        <Cursor />
      </span>
    </>
  );
}

export function SceneSlot({
  index,
  className = "",
  children,
}: {
  index: number;
  className?: string;
  children: ReactNode;
}) {
  return (
    <div className={`ccd-scene ccd-scene-${index} ${className}`} {...(index === 0 ? { "data-active": "" } : {})}>
      {children}
    </div>
  );
}
