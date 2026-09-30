/**
 * The Cursor tab, 1:1 with CursorSettingsPaneAppKit: the live preview box,
 * style/size, fluid movement (tension / friction / mass), smoothing,
 * behaviour (auto-hide, loop to start / stop at end), click effect + click
 * sound, keyboard sounds and the shortcut overlay — every range, step, unit
 * and conditional row of the Mac pane.
 */
import type { ProjectSettings } from "../../core/model";
import { ClickSoundStyle, CursorStyle, KeySoundStyle, KeystrokeOverlayAnimation, KeystrokeOverlayPosition, enumValues } from "../../core/model/enums";
import { ColorSwatch, InspectorButton, PillSlider, Row, ToggleRow } from "../kit";
import { Box, PaneStack } from "./layout";
import { CursorPreviewBox } from "./livePads";
import { Cap, MenuRow, RowButton, fixed, pctRounded, toCodable, toRGBA } from "./shared";
import { resolveFacts, type PaneProps } from "./types";

const STYLES = enumValues(CursorStyle);
const CLICK_STYLES = enumValues(ClickSoundStyle);
const KEY_STYLES = enumValues(KeySoundStyle);
const OVERLAY_POSITIONS = enumValues(KeystrokeOverlayPosition);
const OVERLAY_ANIMATIONS = enumValues(KeystrokeOverlayAnimation);
/** KeystrokeOverlayPosition.label / KeystrokeOverlayAnimation.label */
const POSITION_LABELS: Record<string, string> = {
  bottomCenter: "Bottom Center",
  bottomLeft: "Bottom Left",
  bottomRight: "Bottom Right",
  topCenter: "Top Center",
};
const ANIMATION_LABELS: Record<string, string> = { slideUp: "Slide Up", fade: "Fade", pop: "Pop" };

export function CursorPane({ settings: s, onSettingsChange, onCommit, project, actions, facts: overrides }: PaneProps) {
  const facts = resolveFacts(project, overrides);
  const set = (patch: Partial<ProjectSettings>) => onSettingsChange(patch);
  const pick = (patch: Partial<ProjectSettings>) => {
    onSettingsChange(patch);
    onCommit?.();
  };
  const commit = () => onCommit?.();
  const fluid = s.cursorFluidEnabled;
  const keyOn = s.keySoundEnabled;
  const hasKeyPermission = facts.hasKeyPermission;
  const overlayActive = s.showKeystrokes && facts.hasShortcutData;
  const scopeShown = overlayActive && facts.isWindowRecording;
  const playClick = (style = s.clickSoundStyle, volume = s.clickSoundVolume) => actions?.onPlayClickSound?.(style, volume);
  const playKeys = (style = s.keySoundStyle, volume = s.keySoundVolume) => actions?.onPlayKeySound?.(style, volume);

  return (
    <PaneStack
      items={[
        {
          key: "cursor",
          render: (first) => (
            <Box
              title="Cursor"
              first={first}
              rows={[
                { key: "preview", node: <CursorPreviewBox s={s} /> },
                { key: "show", node: <ToggleRow label="Show Cursor" checked={s.showCursor} onChange={(v) => pick({ showCursor: v })} /> },
                {
                  key: "style",
                  node: <MenuRow label="Style" options={STYLES} selectedIndex={STYLES.indexOf(s.cursorStyle)} onSelect={(i) => pick({ cursorStyle: STYLES[i] })} />,
                },
                {
                  key: "size",
                  node: <PillSlider title="Size" value={s.cursorScale} min={0.5} max={3} step={0.25} format={fixed(2, "x")} onChange={(v) => set({ cursorScale: v })} onCommit={commit} />,
                },
              ]}
            />
          ),
        },
        {
          key: "motion",
          render: (first) => (
            <Box
              title="Motion"
              first={first}
              rows={[
                { key: "fluid", node: <ToggleRow label="Fluid Movement" checked={fluid} onChange={(v) => pick({ cursorFluidEnabled: v })} /> },
                {
                  key: "tension",
                  show: fluid,
                  node: <PillSlider title="Tension" value={s.cursorTension} min={20} max={600} step={10} onChange={(v) => set({ cursorTension: v })} onCommit={commit} />,
                },
                { key: "tensionCap", show: fluid, attached: true, node: <Cap>How quickly the cursor accelerates toward where you moved.</Cap> },
                {
                  key: "friction",
                  show: fluid,
                  node: <PillSlider title="Friction" value={s.cursorFriction} min={2} max={80} step={1} onChange={(v) => set({ cursorFriction: v })} onCommit={commit} />,
                },
                { key: "frictionCap", show: fluid, attached: true, node: <Cap>Resistance while moving fast — higher settles sooner.</Cap> },
                {
                  key: "mass",
                  show: fluid,
                  node: <PillSlider title="Mass" value={s.cursorMass} min={0.2} max={6} step={0.1} format={fixed(1, "x")} onChange={(v) => set({ cursorMass: v })} onCommit={commit} />,
                },
                {
                  key: "massCap",
                  show: fluid,
                  attached: true,
                  node: <Cap>Heavier keeps momentum — more overshoot and wiggle. Clicks always stay exactly where you clicked.</Cap>,
                },
                { key: "smooth", node: <ToggleRow label="Smooth Cursor Motion" checked={s.smoothCursor} onChange={(v) => pick({ smoothCursor: v })} /> },
                {
                  key: "smoothing",
                  show: s.smoothCursor,
                  node: <PillSlider title="Smoothing" value={s.smoothingFactor} min={0.05} max={0.5} step={0.05} onChange={(v) => set({ smoothingFactor: v })} onCommit={commit} />,
                },
              ]}
            />
          ),
        },
        {
          key: "behavior",
          render: (first) => (
            <Box
              title="Behavior"
              first={first}
              rows={[
                { key: "autoHide", node: <ToggleRow label="Auto-Hide Cursor" checked={s.autoHideCursor} onChange={(v) => pick({ autoHideCursor: v })} /> },
                {
                  key: "hideAfter",
                  show: s.autoHideCursor,
                  node: <PillSlider title="Hide After" value={s.autoHideDelay} min={1} max={10} step={0.5} format={fixed(1, "s")} onChange={(v) => set({ autoHideDelay: v })} onCommit={commit} />,
                },
                {
                  key: "loop",
                  node: (
                    <ToggleRow
                      label="Loop to Start"
                      checked={s.cursorLoopToStart}
                      onChange={(v) => pick(v ? { cursorLoopToStart: true, cursorStopAtEnd: false } : { cursorLoopToStart: false })}
                    />
                  ),
                },
                {
                  key: "stop",
                  node: (
                    <ToggleRow
                      label="Stop at End"
                      checked={s.cursorStopAtEnd}
                      onChange={(v) => pick(v ? { cursorStopAtEnd: true, cursorLoopToStart: false } : { cursorStopAtEnd: false })}
                    />
                  ),
                },
                {
                  key: "endCap",
                  attached: true,
                  node: (
                    <Cap>
                      Loop glides the cursor back to its first position near the end — seamless for looping social clips. Stop freezes it for the final half second.
                    </Cap>
                  ),
                },
              ]}
            />
          ),
        },
        {
          key: "click",
          render: (first) => (
            <Box
              title="Click Effect"
              first={first}
              rows={[
                { key: "ripple", node: <ToggleRow label="Show Click Ripple" checked={s.showClickRipple} onChange={(v) => pick({ showClickRipple: v })} /> },
                {
                  key: "rippleSize",
                  show: s.showClickRipple,
                  node: <PillSlider title="Size" value={s.clickRippleSize} min={20} max={100} step={5} onChange={(v) => set({ clickRippleSize: v })} onCommit={commit} />,
                },
                {
                  key: "rippleColor",
                  show: s.showClickRipple,
                  node: (
                    <Row label="Color">
                      <ColorSwatch
                        color={toRGBA(s.clickRippleColor)}
                        supportsOpacity={false}
                        onChange={(c) => set({ clickRippleColor: toCodable(c, s.clickRippleColor) })}
                        ariaLabel="Ripple colour"
                      />
                    </Row>
                  ),
                },
                {
                  key: "clickSound",
                  node: (
                    <ToggleRow
                      label="Click Sound"
                      checked={s.clickSoundEnabled}
                      onChange={(v) => {
                        pick({ clickSoundEnabled: v });
                        if (v) playClick();
                      }}
                    />
                  ),
                },
                {
                  key: "clickStyle",
                  show: s.clickSoundEnabled,
                  node: (
                    <MenuRow
                      label="Sound"
                      options={CLICK_STYLES}
                      selectedIndex={CLICK_STYLES.indexOf(s.clickSoundStyle)}
                      onSelect={(i) => {
                        pick({ clickSoundStyle: CLICK_STYLES[i] });
                        playClick(CLICK_STYLES[i]);
                      }}
                      trailing={<InspectorButton onClick={() => playClick()}>Test</InspectorButton>}
                    />
                  ),
                },
                {
                  key: "clickVolume",
                  show: s.clickSoundEnabled,
                  node: (
                    <PillSlider
                      title="Volume"
                      value={s.clickSoundVolume}
                      min={0.1}
                      max={1}
                      step={0.05}
                      format={pctRounded}
                      onChange={(v) => {
                        set({ clickSoundVolume: v });
                        playClick(s.clickSoundStyle, v);
                      }}
                      onCommit={commit}
                    />
                  ),
                },
                {
                  key: "clickCap",
                  show: s.clickSoundEnabled,
                  attached: true,
                  node: (
                    <Cap line full="A synthesized tick plays at every recorded click — in the preview and in the exported file.">
                      A synthesized tick plays at every recorded click.
                    </Cap>
                  ),
                },
              ]}
            />
          ),
        },
        {
          key: "keys",
          render: (first) => (
            <Box
              title="Keyboard Sounds"
              first={first}
              rows={[
                {
                  key: "keySound",
                  node: (
                    <ToggleRow
                      label="Keyboard Sounds"
                      checked={keyOn}
                      onChange={(v) => {
                        pick({ keySoundEnabled: v });
                        if (v) playKeys();
                      }}
                    />
                  ),
                },
                {
                  key: "keyStyle",
                  show: keyOn,
                  node: (
                    <MenuRow
                      label="Sound"
                      options={KEY_STYLES}
                      selectedIndex={KEY_STYLES.indexOf(s.keySoundStyle)}
                      onSelect={(i) => {
                        pick({ keySoundStyle: KEY_STYLES[i] });
                        playKeys(KEY_STYLES[i]);
                      }}
                      trailing={<InspectorButton onClick={() => playKeys()}>Test</InspectorButton>}
                    />
                  ),
                },
                {
                  key: "keyVolume",
                  show: keyOn,
                  node: <PillSlider title="Volume" value={s.keySoundVolume} min={0.1} max={1} step={0.05} format={pctRounded} onChange={(v) => set({ keySoundVolume: v })} onCommit={commit} />,
                },
                {
                  key: "noData",
                  show: keyOn && !facts.hasKeystrokeData,
                  attached: true,
                  node: (
                    <Cap>
                      This recording has no keystroke data — typing sounds apply to recordings made from now on (with Input Monitoring granted). Record a new take to hear them.
                    </Cap>
                  ),
                },
                {
                  key: "keyCap",
                  show: keyOn && hasKeyPermission && facts.hasKeystrokeData,
                  attached: true,
                  node: (
                    <Cap line full="Keystroke timings (never what you typed) are captured in new recordings and play as typing sounds.">
                      Keystroke timings (never what you typed) play as typing sounds.
                    </Cap>
                  ),
                },
                {
                  key: "permCap",
                  show: keyOn && !hasKeyPermission,
                  node: (
                    <Cap>
                      Grant Input Monitoring in System Settings → Privacy &amp; Security so future recordings can capture keystroke timing. Nothing you type is ever stored — only when keys were pressed.
                    </Cap>
                  ),
                },
                {
                  key: "permButton",
                  show: keyOn && !hasKeyPermission,
                  attached: true,
                  node: <RowButton onClick={actions?.onRequestKeyPermission}>Request Permission</RowButton>,
                },
              ]}
            />
          ),
        },
        {
          key: "overlay",
          render: (first) => (
            <Box
              title="Shortcut Overlay"
              first={first}
              rows={[
                { key: "show", node: <ToggleRow label="Show Shortcut Overlay" checked={s.showKeystrokes} onChange={(v) => pick({ showKeystrokes: v })} /> },
                {
                  key: "position",
                  show: overlayActive,
                  node: (
                    <MenuRow
                      label="Position"
                      options={OVERLAY_POSITIONS.map((p) => POSITION_LABELS[p])}
                      selectedIndex={OVERLAY_POSITIONS.indexOf(s.keystrokeOverlayPosition)}
                      onSelect={(i) => pick({ keystrokeOverlayPosition: OVERLAY_POSITIONS[i] })}
                    />
                  ),
                },
                {
                  key: "animation",
                  show: overlayActive,
                  node: (
                    <MenuRow
                      label="Animation"
                      options={OVERLAY_ANIMATIONS.map((a) => ANIMATION_LABELS[a])}
                      selectedIndex={OVERLAY_ANIMATIONS.indexOf(s.keystrokeOverlayAnimation)}
                      onSelect={(i) => pick({ keystrokeOverlayAnimation: OVERLAY_ANIMATIONS[i] })}
                    />
                  ),
                },
                {
                  key: "size",
                  show: overlayActive,
                  node: (
                    <PillSlider title="Size" value={s.keystrokeOverlaySize} min={0.6} max={1.8} step={0.1} format={pctRounded} onChange={(v) => set({ keystrokeOverlaySize: v })} onCommit={commit} />
                  ),
                },
                {
                  key: "scope",
                  show: scopeShown,
                  node: (
                    <ToggleRow
                      label="Only Recorded App"
                      checked={s.keystrokeOverlayScopeToRecordedApp}
                      onChange={(v) => pick({ keystrokeOverlayScopeToRecordedApp: v })}
                    />
                  ),
                },
                {
                  key: "scopeCap",
                  show: scopeShown,
                  attached: true,
                  node: (
                    <Cap line full="Hide shortcuts pressed in other apps while this window was being recorded.">
                      Hide shortcuts pressed in other apps during the recording.
                    </Cap>
                  ),
                },
                {
                  key: "noData",
                  show: s.showKeystrokes && !facts.hasShortcutData,
                  attached: true,
                  node: (
                    <Cap>
                      This recording has no shortcut data. Enable "Capture Shortcuts" in the recording panel before recording — only combos with ⌘, ⌃ or ⌥ are stored, never plain typing.
                    </Cap>
                  ),
                },
                {
                  key: "overlayCap",
                  show: overlayActive,
                  attached: true,
                  node: (
                    <Cap line full="Recorded shortcuts (⌘⇧S…) appear as a pill, in the preview and in the exported file.">
                      Recorded shortcuts (⌘⇧S…) appear as a pill in preview and export.
                    </Cap>
                  ),
                },
              ]}
            />
          ),
        },
      ]}
    />
  );
}
