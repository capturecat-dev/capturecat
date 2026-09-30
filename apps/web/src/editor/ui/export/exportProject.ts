/**
 * The export flow behind the Export sheet — the web twin of
 * `ExportSheetController.startExport()`: resolve the sheet's settings to the
 * exporter's output size / fps / bitrate (the SAME `ExportSettings` math the
 * Mac uses, core/math/aspectRatio.ts), run the engine export (same passes as
 * the preview + the project's audio mix), and deliver the file.
 *
 * Delivery replaces NSSavePanel + "reveal in Finder": a save-file picker
 * chosen BEFORE rendering when the browser has one (the Mac asks for the
 * location first too), otherwise a download once the file exists.
 */
import { gifCaption } from "../../core/export/gifPolicy";
import { estimatedVideoBitRate, qualityPresetName, resolvedOutputSize } from "../../core/math/aspectRatio";
import { formatFixed } from "../../core/math/swift";
import type { AspectRatio } from "../../core/model/enums";
import type { EngineClient } from "../../engine/client";
import type { ExportResult } from "../../engine/protocol";

/** `ExportSettings` (Models/ExportSettings.swift) — raw values are persistence identity. */
export interface SheetExportSettings {
  format: "MP4" | "MOV" | "GIF";
  resolution: "720p" | "1080p" | "4K" | "Custom";
  fps: number;
  quality: number;
  customWidth: number;
  customHeight: number;
  collapseStaticSpans: boolean;
}

export const DEFAULT_SHEET_SETTINGS: SheetExportSettings = {
  format: "MP4",
  resolution: "1080p",
  fps: 60,
  quality: 0.85,
  customWidth: 1920,
  customHeight: 1080,
  collapseStaticSpans: true,
};

export const EXPORT_FORMATS = ["MP4", "MOV", "GIF"] as const;

/** What the sheet produces: a still's PNG (Type row "Image (PNG)") or a movie / GIF. */
export type ExportKind = "image" | "video";
/** A file the sheet can write: the movie formats plus the still's PNG. */
export type ExportFileFormat = SheetExportSettings["format"] | "PNG";
export const EXPORT_RESOLUTIONS = ["720p", "1080p", "4K", "Custom"] as const;

type Json = Record<string, unknown>;

/** `project.settings.exportSettings` with the Swift decode defaults. */
export function sheetSettingsFromDoc(doc: Json | null | undefined): SheetExportSettings {
  const e = ((doc?.settings as Json | undefined)?.exportSettings ?? {}) as Json;
  const d = DEFAULT_SHEET_SETTINGS;
  const pick = <T extends string>(v: unknown, all: readonly T[], def: T): T =>
    typeof v === "string" && (all as readonly string[]).includes(v) ? (v as T) : def;
  const int = (v: unknown, def: number) => (typeof v === "number" && Number.isFinite(v) ? Math.trunc(v) : def);
  return {
    format: pick(e.format, EXPORT_FORMATS, d.format),
    resolution: pick(e.resolution, EXPORT_RESOLUTIONS, d.resolution),
    fps: int(e.fps, d.fps),
    quality: typeof e.quality === "number" && Number.isFinite(e.quality) ? e.quality : d.quality,
    customWidth: int(e.customWidth, d.customWidth),
    customHeight: int(e.customHeight, d.customHeight),
    collapseStaticSpans: typeof e.collapseStaticSpans === "boolean" ? e.collapseStaticSpans : d.collapseStaticSpans,
  };
}

/** Writes the sheet's settings into a project document (`project.settings.exportSettings = exportSettings`). */
export function withSheetSettings(doc: Json, s: SheetExportSettings): Json {
  const settings = (doc.settings as Json | undefined) ?? {};
  const prev = (settings.exportSettings as Json | undefined) ?? {};
  return { ...doc, settings: { ...settings, exportSettings: { ...prev, ...s } } };
}

export interface ExportGeometry {
  width: number;
  height: number;
  fps: number;
  bitrate: number;
}

/** Output size / fps / bitrate exactly as VideoExporter derives them from the settings. */
export function exportGeometry(s: SheetExportSettings, aspectRatio: string, sourceSize: { width: number; height: number }): ExportGeometry {
  const size = resolvedOutputSize(s, aspectRatio as AspectRatio, sourceSize);
  return {
    width: size.width,
    height: size.height,
    fps: s.fps,
    bitrate: estimatedVideoBitRate(s, aspectRatio as AspectRatio, sourceSize),
  };
}

/**
 * `ExportSettings.estimatedBitRateDescription(for:sourceSize:)` — "Master • 1920x1080 @ 60 fps • ~31.1 Mbps";
 * for GIF the sheet shows `GIFExportPolicy.caption` ("GIF • 960x540 @ 20 fps • loops").
 */
export function estimatedBitRateDescription(s: SheetExportSettings, aspectRatio: string, sourceSize: { width: number; height: number }): string {
  const g = exportGeometry(s, aspectRatio, sourceSize);
  if (s.format === "GIF") return gifCaption(g, s.fps);
  const mbps = g.bitrate / 1_000_000;
  return `${qualityPresetName(s)} • ${g.width}x${g.height} @ ${s.fps} fps • ~${formatFixed(mbps, 1)} Mbps`;
}

/** The file name the Mac's save panel proposes: "<project name>.<ext>". */
export function exportFileName(projectName: string, format: ExportFileFormat): string {
  const ext = format === "MOV" ? "mov" : format === "GIF" ? "gif" : format === "PNG" ? "png" : "mp4";
  const base = (projectName || "Untitled").replace(/[\\/:*?"<>|]+/g, "-").trim() || "Untitled";
  return `${base}.${ext}`;
}

// ── Delivery ─────────────────────────────────────────────────────────────

interface WritableLike {
  write(data: Blob): Promise<void>;
  close(): Promise<void>;
}
export interface SaveTarget {
  createWritable(): Promise<WritableLike>;
}
type SavePicker = (opts: {
  suggestedName: string;
  types?: { description: string; accept: Record<string, string[]> }[];
}) => Promise<SaveTarget>;

/**
 * The browser's save panel (File System Access), or null when unavailable —
 * then the finished file downloads instead. Throws `AbortError` when the user
 * cancels (the Mac's `panel.runModal() != .OK` → no export).
 */
export async function pickSaveTarget(fileName: string, format: ExportFileFormat): Promise<SaveTarget | null> {
  const picker = (globalThis as { showSaveFilePicker?: SavePicker }).showSaveFilePicker;
  if (!picker) return null;
  const [mime, ext] =
    format === "MOV"
      ? ["video/quicktime", ".mov"]
      : format === "GIF"
        ? ["image/gif", ".gif"]
        : format === "PNG"
          ? ["image/png", ".png"]
          : ["video/mp4", ".mp4"];
  return picker({ suggestedName: fileName, types: [{ description: `${format} file`, accept: { [mime]: [ext] } }] });
}

export function downloadBlob(blob: Blob, fileName: string): void {
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = fileName;
  a.rel = "noopener";
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 60_000);
}

// ── Export ───────────────────────────────────────────────────────────────

export interface ExportProjectOptions {
  settings: SheetExportSettings;
  /** `settings.aspectRatio` raw value ("Auto", "16:9", …). */
  aspectRatio: string;
  /** The recording's natural size (LoadedInfo width/height) — decides "Auto". */
  sourceSize: { width: number; height: number };
  projectName: string;
  /** "image" = the still's PNG (StillImageExporter); default "video" (`settings.format`). */
  kind?: ExportKind;
  /** Where the file goes: a picked file, "download" (default), or "none" (caller handles the blob). */
  delivery?: SaveTarget | "download" | "none";
  /** Aborting stops the render (the engine's `cancelExport`). */
  signal?: AbortSignal;
}

export interface ExportProjectResult {
  blob: Blob;
  fileName: string;
  result: ExportResult;
}

/**
 * Runs the export and delivers the file. `onProgress(fraction)` follows the
 * rendered frames (the Mac sheet polls `exporter.progress` the same way).
 * Rejects with an `AbortError` DOMException when cancelled.
 */
export async function exportProject(
  client: EngineClient,
  options: ExportProjectOptions,
  onProgress?: (fraction: number) => void,
): Promise<ExportProjectResult> {
  const { settings, aspectRatio, sourceSize, signal } = options;
  if (signal?.aborted) throw new DOMException("Export cancelled.", "AbortError");
  const g = exportGeometry(settings, aspectRatio, sourceSize);
  const format: ExportFileFormat = options.kind === "image" ? "PNG" : settings.format;
  const onAbort = () => client.cancelExport();
  signal?.addEventListener("abort", onAbort, { once: true });
  let result: ExportResult;
  try {
    result = await client.export(
      {
        // GIF: the exporter applies core/export/gifPolicy to this size + fps.
        width: g.width,
        height: g.height,
        fps: g.fps,
        bitrate: g.bitrate,
        format,
        // Fast export (VFR) — movies only; GIFs are always dense.
        collapseStaticSpans: (format === "MP4" || format === "MOV") && settings.collapseStaticSpans,
        audio: format === "MP4" || format === "MOV",
      },
      (done, total) => onProgress?.(total > 0 ? done / total : 0),
    );
  } catch (e) {
    if ((e as { code?: string }).code === "cancelled" || signal?.aborted) throw new DOMException("Export cancelled.", "AbortError");
    throw e;
  } finally {
    signal?.removeEventListener("abort", onAbort);
  }
  onProgress?.(1);
  const fileName = exportFileName(options.projectName, format);
  const blob = new Blob([result.buffer], { type: result.mimeType });
  const delivery = options.delivery ?? "download";
  if (delivery === "download") downloadBlob(blob, fileName);
  else if (delivery !== "none") {
    const w = await delivery.createWritable();
    await w.write(blob);
    await w.close();
  }
  return { blob, fileName, result };
}
