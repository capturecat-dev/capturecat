/**
 * The Export sheet — a 1:1 port of `Views/AppKitSurfaces/ExportSheetController.swift`
 * on the editor kit: a CCDialog card (title / scrollable rows / trailing
 * footer, 430 wide, content capped at 440 then scrolling) with
 *
 *   Format       MP4 | MOV | GIF
 *   Resolution   720p | 1080p | 4K | Custom   (+ "Size  W × H" when Custom)
 *   Frame Rate   30 fps | 60 fps
 *   Quality      50–100 % (step 5 %) + the "Master • 1920x1080 @ 60 fps • ~31.1 Mbps" caption
 *   Fast export (collapse still frames)
 *   [Share link after export / Allow viewer comments — when the host can share]
 *   error caption                                   [Cancel] [Export]
 *
 * and the exporting state ("Exporting…", a 280-wide CCProgressBar whose fill
 * springs, "NN%"). Motion is the Mac's: the card enters with the Keynote
 * scale-in (0.96 → 1, smooth spring) over a fading scrim, and every content
 * change (the Size row, form ⇄ progress) grows the card from its pinned top
 * edge on the house bounce — the bottom is the pushed edge.
 *
 * Web differences (deliberate): Cancel stays live while exporting and stops
 * the render (the Mac disables it); the save location is the browser's save
 * picker when available, else a download.
 */
import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { createPortal } from "react-dom";

import type { EngineClient } from "../../engine/client";
import { animateCurve, animateSpring, curves, durations, tween } from "../kit/motion";
import { InspectorButton, PillSlider, Row, Select, TextField, ToggleRow, useCCTheme } from "../kit";
import {
  EXPORT_FORMATS,
  EXPORT_RESOLUTIONS,
  estimatedBitRateDescription,
  exportFileName,
  exportProject,
  pickSaveTarget,
  sheetSettingsFromDoc,
  type ExportProjectResult,
  type SaveTarget,
  type SheetExportSettings,
} from "./exportProject";

type Json = Record<string, unknown>;

export interface ExportDialogProps {
  open: boolean;
  /** Dismiss (Cancel, Escape, or a finished export). */
  onClose: () => void;
  /** The mounted engine (the export renders with the preview's passes). */
  client: EngineClient | null;
  /** The project document as edited (name, aspect ratio, export settings). */
  project: Json | null;
  /** The recording's natural size (`LoadedInfo.width/height`) — decides the "Auto" aspect. */
  sourceSize: { width: number; height: number } | null;
  /** Export started with these settings — persist them (`project.settings.exportSettings = exportSettings`). */
  onSettingsCommit?: (settings: SheetExportSettings) => void;
  /**
   * When the host can upload shares, the sheet shows the Mac's "Share link
   * after export" + "Allow viewer comments" toggles and hands the finished
   * file here when sharing was ticked.
   */
  onShareAfterExport?: (file: ExportProjectResult, opts: { allowComments: boolean }) => void;
}

const WIDTH = 430;
const MAX_CONTENT = 440;
const EDGE_MARGIN = 16;

export function ExportDialog(props: ExportDialogProps) {
  const { open } = props;
  const [present, setPresent] = useState(open);
  const [closing, setClosing] = useState(false);
  useEffect(() => {
    if (open) {
      setPresent(true);
      setClosing(false);
    } else if (present) {
      setClosing(true);
    }
  }, [open, present]);
  if (!present) return null;
  return <ExportSheet {...props} closing={closing} onExited={() => setPresent(false)} />;
}

function ExportSheet({
  onClose,
  client,
  project,
  sourceSize,
  onSettingsCommit,
  onShareAfterExport,
  closing,
  onExited,
}: ExportDialogProps & { closing: boolean; onExited: () => void }) {
  const { portal } = useCCTheme();
  const [settings, setSettings] = useState<SheetExportSettings>(() => sheetSettingsFromDoc(project));
  const [widthDraft, setWidthDraft] = useState(String(settings.customWidth));
  const [heightDraft, setHeightDraft] = useState(String(settings.customHeight));
  const [share, setShare] = useState(false);
  const [allowComments, setAllowComments] = useState(false);
  const [exporting, setExporting] = useState(false);
  const [progress, setProgress] = useState(0);
  const [error, setError] = useState<string | null>(null);
  const abortRef = useRef<AbortController | null>(null);

  const cardRef = useRef<HTMLDivElement>(null);
  const scrimRef = useRef<HTMLDivElement>(null);
  const holderRef = useRef<HTMLDivElement>(null);
  const stackRef = useRef<HTMLDivElement>(null);
  const [top, setTop] = useState<number | null>(null);

  const aspectRatio = typeof (project?.settings as Json | undefined)?.aspectRatio === "string"
    ? ((project!.settings as Json).aspectRatio as string)
    : "Auto";
  const projectName = typeof project?.name === "string" ? project.name : "Untitled";
  const source = sourceSize ?? { width: 1920, height: 1080 };
  const caption = useMemo(() => estimatedBitRateDescription(settings, aspectRatio, source), [settings, aspectRatio, source.width, source.height]); // eslint-disable-line react-hooks/exhaustive-deps

  // ── Presentation: scrim fade + Keynote scale-in; top edge pinned after.
  useLayoutEffect(() => {
    const card = cardRef.current;
    const holder = holderRef.current;
    const stack = stackRef.current;
    if (!card || !holder || !stack) return;
    holder.style.height = `${Math.min(MAX_CONTENT, stack.offsetHeight)}px`;
    setTop(Math.max(EDGE_MARGIN, Math.round((window.innerHeight - card.offsetHeight) / 2)));
    card.style.transformOrigin = "50% 50%";
    animateSpring(card, [{ transform: "scale(0.96)" }, { transform: "scale(1)" }], "smooth");
    animateCurve(card, [{ opacity: 0 }, { opacity: 1 }], { duration: 0.22, curve: curves.glide });
    if (scrimRef.current) animateCurve(scrimRef.current, [{ opacity: 0 }, { opacity: 1 }], { duration: 0.22, curve: curves.glide });
  }, [portal]);

  useEffect(() => {
    if (!closing) return;
    const card = cardRef.current;
    const scrim = scrimRef.current;
    if (!card || !scrim) return onExited();
    animateSpring(card, [{ transform: "scale(1)" }, { transform: "scale(0.97)" }], "snappy");
    animateCurve(scrim, [{ opacity: 1 }, { opacity: 0 }], { duration: 0.18, curve: curves.glide });
    const a = animateCurve(card, [{ opacity: 1 }, { opacity: 0 }], { duration: 0.18, curve: curves.glide });
    if (!a) return onExited();
    a.addEventListener("finish", onExited, { once: true });
  }, [closing, onExited]);

  // ── Growth: content changes move the bottom edge on the house bounce.
  useEffect(() => {
    const holder = holderRef.current;
    const stack = stackRef.current;
    if (!holder || !stack) return;
    let cancel: (() => void) | null = null;
    let current = holder.getBoundingClientRect().height;
    const ro = new ResizeObserver(() => {
      const target = Math.min(MAX_CONTENT, stack.offsetHeight);
      if (Math.abs(target - current) < 0.5) return;
      cancel?.();
      const from = current;
      cancel = tween(
        from,
        target,
        (v) => {
          current = v;
          holder.style.height = `${Math.max(0, v)}px`;
        },
        { duration: durations.grow, curve: curves.bounce },
      );
    });
    ro.observe(stack);
    return () => {
      ro.disconnect();
      cancel?.();
    };
  }, [portal]);

  const update = useCallback((patch: Partial<SheetExportSettings>) => setSettings((s) => ({ ...s, ...patch })), []);

  const commitCustomSize = useCallback((): SheetExportSettings => {
    // `commitCustomSizeFields`: positive integers only; anything else keeps the old value.
    const w = Number.parseInt(widthDraft, 10);
    const h = Number.parseInt(heightDraft, 10);
    const next = {
      ...settings,
      customWidth: Number.isFinite(w) && w > 0 && /^\s*\d+\s*$/.test(widthDraft) ? w : settings.customWidth,
      customHeight: Number.isFinite(h) && h > 0 && /^\s*\d+\s*$/.test(heightDraft) ? h : settings.customHeight,
    };
    setSettings(next);
    setWidthDraft(String(next.customWidth));
    setHeightDraft(String(next.customHeight));
    return next;
  }, [widthDraft, heightDraft, settings]);

  const dismiss = useCallback(() => {
    if (exporting) return;
    onClose();
  }, [exporting, onClose]);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") {
        e.preventDefault();
        dismiss();
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [dismiss]);

  const startExport = useCallback(async () => {
    if (!client || exporting) return;
    const s = commitCustomSize();
    const fileName = exportFileName(projectName, s.format);
    // The save location first, like NSSavePanel; a cancelled picker = no export.
    let target: SaveTarget | null = null;
    try {
      target = await pickSaveTarget(fileName, s.format);
    } catch (e) {
      if ((e as DOMException)?.name === "AbortError") return;
      target = null;
    }
    setError(null);
    setProgress(0);
    setExporting(true);
    onSettingsCommit?.(s);
    const abort = new AbortController();
    abortRef.current = abort;
    try {
      const file = await exportProject(
        client,
        { settings: s, aspectRatio, sourceSize: source, projectName, delivery: target ?? "download", signal: abort.signal },
        (f) => setProgress(f),
      );
      setExporting(false);
      if (share && onShareAfterExport) onShareAfterExport(file, { allowComments });
      onClose();
    } catch (e) {
      setExporting(false);
      if ((e as DOMException)?.name !== "AbortError") setError(e instanceof Error ? e.message : String(e));
    } finally {
      abortRef.current = null;
    }
  }, [client, exporting, commitCustomSize, projectName, onSettingsCommit, aspectRatio, source, share, onShareAfterExport, allowComments, onClose]);

  const cancel = useCallback(() => {
    if (exporting) abortRef.current?.abort();
    else dismiss();
  }, [exporting, dismiss]);

  if (!portal) return null;
  const percent = Math.trunc(Math.min(1, Math.max(0, progress)) * 100);
  const maxWidth = typeof window === "undefined" ? WIDTH : Math.min(WIDTH, window.innerWidth - 2 * EDGE_MARGIN);

  return createPortal(
    <div className="cc-export">
      <div ref={scrimRef} className="cc-export__scrim" onPointerDown={(e) => e.target === e.currentTarget && e.preventDefault()} />
      <div
        ref={cardRef}
        className="cc-dialog cc-mat-matte"
        role="dialog"
        aria-modal="true"
        aria-label="Export Video"
        style={{ width: maxWidth, top: top ?? undefined, visibility: top === null ? "hidden" : undefined }}
      >
        <div className="cc-dialog__header">
          <div className="cc-dialog__title">Export Video</div>
        </div>
        <div ref={holderRef} className="cc-dialog__content">
          <div ref={stackRef} className="cc-dialog__stack">
            {!exporting ? (
              <div className="cc-export__form">
                <Row label="Format">
                  <Select
                    options={EXPORT_FORMATS.map((f) => ({ title: f }))}
                    selectedIndex={Math.max(0, EXPORT_FORMATS.indexOf(settings.format))}
                    onSelect={(i) => update({ format: EXPORT_FORMATS[i] })}
                    size="sm"
                    minTriggerWidth={120}
                    ariaLabel="Format"
                  />
                </Row>
                <Row label="Resolution">
                  <Select
                    options={EXPORT_RESOLUTIONS.map((r) => ({ title: r }))}
                    selectedIndex={EXPORT_RESOLUTIONS.indexOf(settings.resolution) >= 0 ? EXPORT_RESOLUTIONS.indexOf(settings.resolution) : 1}
                    onSelect={(i) => update({ resolution: EXPORT_RESOLUTIONS[i] })}
                    size="sm"
                    minTriggerWidth={120}
                    ariaLabel="Resolution"
                  />
                </Row>
                {settings.resolution === "Custom" && (
                  <Row label="Size">
                    <span className="cc-export__size">
                      <TextField
                        size="sm"
                        className="cc-export__dim"
                        placeholder="Width"
                        inputMode="numeric"
                        value={widthDraft}
                        onChange={(e) => setWidthDraft(e.target.value)}
                        onBlur={commitCustomSize}
                        onKeyDown={(e) => e.key === "Enter" && (e.target as HTMLInputElement).blur()}
                        aria-label="Width"
                      />
                      <span className="cc-export__x">×</span>
                      <TextField
                        size="sm"
                        className="cc-export__dim"
                        placeholder="Height"
                        inputMode="numeric"
                        value={heightDraft}
                        onChange={(e) => setHeightDraft(e.target.value)}
                        onBlur={commitCustomSize}
                        onKeyDown={(e) => e.key === "Enter" && (e.target as HTMLInputElement).blur()}
                        aria-label="Height"
                      />
                    </span>
                  </Row>
                )}
                <Row label="Frame Rate">
                  <Select
                    options={[{ title: "30 fps" }, { title: "60 fps" }]}
                    selectedIndex={settings.fps === 30 ? 0 : 1}
                    onSelect={(i) => update({ fps: i === 0 ? 30 : 60 })}
                    size="sm"
                    minTriggerWidth={120}
                    ariaLabel="Frame Rate"
                  />
                </Row>
                <PillSlider
                  title="Quality"
                  value={settings.quality}
                  min={0.5}
                  max={1}
                  step={0.05}
                  format={(v) => `${Math.round(v * 100)}%`}
                  onChange={(v) => update({ quality: v })}
                />
                <div className="cc-caption cc-export__bitrate">{caption}</div>
                <ToggleRow
                  label="Fast export (collapse still frames)"
                  checked={settings.collapseStaticSpans}
                  onChange={(v) => update({ collapseStaticSpans: v })}
                />
                {onShareAfterExport && (
                  <>
                    <ToggleRow label="Share link after export" checked={share} onChange={setShare} />
                    {share && <ToggleRow label="Allow viewer comments on the share page" checked={allowComments} onChange={setAllowComments} />}
                  </>
                )}
                {error && <div className="cc-caption cc-export__error">{error}</div>}
              </div>
            ) : (
              <div className="cc-export__progress" aria-live="polite">
                <div className="cc-export__progress-title">Exporting…</div>
                <div className="cc-progress cc-mat-recessed cc-mat-pill" role="progressbar" aria-valuemin={0} aria-valuemax={100} aria-valuenow={percent}>
                  <div className="cc-progress__clip" style={{ width: `${Math.min(1, Math.max(0, progress)) * 100}%` }}>
                    <div className="cc-progress__fill cc-mat-raised cc-mat-short" />
                  </div>
                </div>
                <div className="cc-export__percent">{percent}%</div>
              </div>
            )}
          </div>
        </div>
        <div className="cc-dialog__footer">
          <InspectorButton onClick={cancel}>Cancel</InspectorButton>
          <InspectorButton onClick={() => void startExport()} disabled={exporting || !client}>
            Export
          </InspectorButton>
        </div>
      </div>
    </div>,
    portal,
  );
}
