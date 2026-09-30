/**
 * The Subtitles tab, 1:1 with SubtitleSettingsPaneAppKit: show switch,
 * generate / manage (Whisper transcription is state/subtitleGeneration.ts's
 * job — progress, error, Cancel and the "N subtitles · Regenerate · Delete"
 * row mirror the Mac),
 * preset cards with live styled "Aa", Text (size, font, weight chips,
 * uppercase, colour), Style (position chips + drag pad, style chips,
 * background colour, karaoke + highlight) and the editable caption cards.
 */
import type { ProjectSettings } from "../../core/model";
import { SubtitlePosition, SubtitleStyle, SubtitleWeight, enumValues } from "../../core/model/enums";
import { applySubtitlePreset, subtitlePresetMatches, subtitlePresets } from "../../core/model/helpers";
import { Chips, ColorSwatch, InspectorButton, InspectorField, PillSlider, Row, ToggleRow } from "../kit";
import { WHISPER_DOWNLOAD_MB } from "../../transcribe/model";
import { formatTimecode } from "../timeline/snap";
import { Box, PaneStack } from "./layout";
import { SubtitlePositionPad, SubtitlePresetCard } from "./livePads";
import { Cap, MenuRow, RowButton, toCodable, toRGBA } from "./shared";
import type { PaneProps } from "./types";

/** InspectorKit caption under Generate (the Mac's copy; the size is the web
 *  model's WebGPU download — the editor requires WebGPU). */
export const GENERATE_CAPTION = `Auto-transcribes audio with Whisper AI. The model downloads automatically on first use (~${WHISPER_DOWNLOAD_MB.webgpu} MB).`;

const POSITIONS = enumValues(SubtitlePosition);
const STYLES = enumValues(SubtitleStyle);
const WEIGHTS = enumValues(SubtitleWeight);

/** FontCatalog: "System" + the curated faces (the Mac filters them to the
 *  installed families and appends every other family; the browser cannot
 *  enumerate fonts, so the curated list stands). */
export const FONT_MENU = [
  "System",
  "SF Pro",
  "SF Pro Rounded",
  "New York",
  "Helvetica Neue",
  "Avenir Next",
  "Futura",
  "Gill Sans",
  "Georgia",
  "Times New Roman",
  "Palatino",
  "Menlo",
  "SF Mono",
  "Courier New",
  "Impact",
  "Copperplate",
  "American Typewriter",
];
/** FontCatalog.menuIndex(for:) */
export const fontMenuIndex = (name: string | undefined) => (name && name !== "System" ? Math.max(0, FONT_MENU.indexOf(name)) : 0);
/** FontCatalog.storedName(forMenuIndex:) — nil (omitted) for System. */
export const fontStoredName = (i: number) => (i > 0 && i < FONT_MENU.length ? FONT_MENU[i] : undefined);

export function SubtitlesPane({ settings: s, onSettingsChange, onCommit, project, onRegionChange, onProjectChange, actions }: PaneProps) {
  const set = (patch: Partial<ProjectSettings>) => onSettingsChange(patch);
  const pick = (patch: Partial<ProjectSettings>) => {
    onSettingsChange(patch);
    onCommit?.();
  };
  const commit = () => onCommit?.();
  const show = s.showSubtitles;
  const subtitles = project?.subtitles ?? [];
  const has = subtitles.length > 0;
  const busy = actions?.subtitleStatus?.busy ?? false;
  const error = actions?.subtitleStatus?.error ?? null;

  return (
    <PaneStack
      items={[
        {
          key: "subtitles",
          render: (first) => (
            <Box
              title="Subtitles"
              first={first}
              rows={[
                { key: "show", node: <ToggleRow label="Show Subtitles" checked={show} onChange={(v) => pick({ showSubtitles: v })} /> },
                {
                  key: "generate",
                  show: show && !has && !busy,
                  node: <RowButton onClick={actions?.onGenerateSubtitles}>Generate Subtitles</RowButton>,
                },
                {
                  key: "generateCap",
                  show: show && !has && !busy,
                  attached: true,
                  node: <Cap>{GENERATE_CAPTION}</Cap>,
                },
                {
                  key: "spinner",
                  show: show && busy,
                  node: (
                    <div className="cc-pane-hstack">
                      <span className="cc-spin" aria-label="Transcribing" />
                      <span className="cc-spacer" />
                      {actions?.onCancelSubtitles ? <InspectorButton onClick={actions.onCancelSubtitles}>Cancel</InspectorButton> : null}
                    </div>
                  ),
                },
                { key: "progress", show: show && busy, attached: true, node: <Cap>{actions?.subtitleStatus?.progress ?? ""}</Cap> },
                { key: "error", show: show && !!error, attached: true, node: <div className="cc-pane-error">{error ?? ""}</div> },
                {
                  key: "manage",
                  // Hidden while a run is in flight, like the Mac (whose
                  // Regenerate had already emptied the list).
                  show: show && has && !busy,
                  node: (
                    <div className="cc-pane-hstack">
                      <span className="cc-pane-count">{subtitles.length} subtitles</span>
                      <span className="cc-spacer" />
                      {/* Regenerate never clears first: the cues are replaced
                          only once new ones exist (a failed or cancelled run
                          keeps them). */}
                      <InspectorButton onClick={() => (actions?.onRegenerateSubtitles ?? actions?.onGenerateSubtitles)?.()}>
                        Regenerate
                      </InspectorButton>
                      <InspectorButton
                        destructive
                        onClick={() => {
                          if (actions?.onDeleteSubtitles) actions.onDeleteSubtitles();
                          else onProjectChange?.({ subtitles: [] });
                        }}
                      >
                        Delete
                      </InspectorButton>
                    </div>
                  ),
                },
              ]}
            />
          ),
        },
        {
          key: "presets",
          show: show,
          render: (first) => (
            <Box
              title="Presets"
              first={first}
              rows={[
                {
                  key: "cards",
                  node: (
                    <div className="cc-subpresets">
                      {subtitlePresets.map((preset) => (
                        <SubtitlePresetCard
                          key={preset.id}
                          preset={preset}
                          active={subtitlePresetMatches(preset, s)}
                          onClick={() => {
                            const next = applySubtitlePreset(preset, s);
                            pick({
                              subtitleStyle: next.subtitleStyle,
                              subtitleWeight: next.subtitleWeight,
                              subtitleUppercase: next.subtitleUppercase,
                              subtitleColor: next.subtitleColor,
                              subtitleBackgroundColor: next.subtitleBackgroundColor,
                              highlightWords: next.highlightWords,
                              subtitleHighlightColor: next.subtitleHighlightColor,
                            });
                          }}
                        />
                      ))}
                    </div>
                  ),
                },
              ]}
            />
          ),
        },
        {
          key: "text",
          show: show,
          render: (first) => (
            <Box
              title="Text"
              first={first}
              rows={[
                { key: "size", node: <PillSlider title="Size" value={s.subtitleFontSize} min={16} max={64} step={2} onChange={(v) => set({ subtitleFontSize: v })} onCommit={commit} /> },
                {
                  key: "font",
                  node: <MenuRow label="Font" options={FONT_MENU} selectedIndex={fontMenuIndex(s.subtitleFontName)} onSelect={(i) => pick({ subtitleFontName: fontStoredName(i) })} />,
                },
                {
                  key: "weight",
                  node: <Chips items={WEIGHTS} selectedIndex={Math.max(0, WEIGHTS.indexOf(s.subtitleWeight))} onSelect={(i) => pick({ subtitleWeight: WEIGHTS[i] })} ariaLabel="Weight" />,
                },
                { key: "upper", node: <ToggleRow label="Uppercase" checked={s.subtitleUppercase} onChange={(v) => pick({ subtitleUppercase: v })} /> },
                {
                  key: "color",
                  node: (
                    <Row label="Color">
                      <ColorSwatch color={toRGBA(s.subtitleColor)} onChange={(c) => set({ subtitleColor: toCodable(c, s.subtitleColor) })} ariaLabel="Subtitle colour" />
                    </Row>
                  ),
                },
              ]}
            />
          ),
        },
        {
          key: "style",
          show: show,
          render: (first) => (
            <Box
              title="Style"
              first={first}
              rows={[
                {
                  key: "position",
                  node: (
                    <Chips
                      items={POSITIONS}
                      selectedIndex={Math.max(0, POSITIONS.indexOf(s.subtitlePosition))}
                      // A stock anchor clears free placement (pad/preview drag).
                      onSelect={(i) => pick({ subtitlePosition: POSITIONS[i], subtitleCustomX: undefined, subtitleCustomY: undefined })}
                      ariaLabel="Position"
                    />
                  ),
                },
                {
                  key: "pad",
                  attached: true,
                  node: (
                    <SubtitlePositionPad
                      s={s}
                      onPlace={(x, y) => set({ subtitleCustomX: x, subtitleCustomY: y })}
                      onSnap={(anchor) => pick({ subtitlePosition: anchor, subtitleCustomX: undefined, subtitleCustomY: undefined })}
                    />
                  ),
                },
                {
                  key: "style",
                  node: <Chips items={STYLES} selectedIndex={Math.max(0, STYLES.indexOf(s.subtitleStyle))} onSelect={(i) => pick({ subtitleStyle: STYLES[i] })} ariaLabel="Style" />,
                },
                {
                  key: "bg",
                  show: s.subtitleStyle === "Background",
                  node: (
                    <Row label="Background">
                      <ColorSwatch
                        color={toRGBA(s.subtitleBackgroundColor)}
                        onChange={(c) => set({ subtitleBackgroundColor: toCodable(c, s.subtitleBackgroundColor) })}
                        ariaLabel="Background colour"
                      />
                    </Row>
                  ),
                },
                { key: "karaoke", node: <ToggleRow label="Karaoke Highlight" checked={s.highlightWords} onChange={(v) => pick({ highlightWords: v })} /> },
                {
                  key: "highlight",
                  show: s.highlightWords,
                  node: (
                    <Row label="Highlight">
                      <ColorSwatch
                        color={toRGBA(s.subtitleHighlightColor)}
                        onChange={(c) => set({ subtitleHighlightColor: toCodable(c, s.subtitleHighlightColor) })}
                        ariaLabel="Highlight colour"
                      />
                    </Row>
                  ),
                },
              ]}
            />
          ),
        },
        {
          key: "edit",
          show: show && has,
          render: (first) => (
            <Box
              title="Edit Subtitles"
              first={first}
              rows={[
                {
                  key: "cards",
                  node: (
                    <div className="cc-capcards">
                      {subtitles.map((seg) => (
                        <div key={seg.id} className="cc-capcard">
                          <span className="cc-capcard__time">
                            {formatTimecode(seg.startTime)} — {formatTimecode(seg.endTime)}
                          </span>
                          <InspectorField
                            placeholder="Text"
                            value={seg.text}
                            onChange={(e) => onRegionChange?.("subtitle", seg.id, { text: e.target.value })}
                            onBlur={commit}
                          />
                        </div>
                      ))}
                    </div>
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
