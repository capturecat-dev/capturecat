/**
 * `serializeProject(p)` — the web twin of `JSONEncoder().encode(project)`.
 *
 * Reproduces every `encode(to:)` in apps/macos/CaptureCat/Models: key names,
 * which nil Optionals are written as JSON null (`c.encode(optional)`) versus
 * omitted (`encodeIfPresent`), the on-disk shapes that differ from the
 * in-memory model (ZoomRegion.focalPoint → `[x, y]`; region `rect` →
 * rectX/rectY/rectW/rectH), then re-appends each object's `$extra` keys
 * verbatim so unknown data survives the round trip.
 *
 * Mirrors Swift's refusal to write invalid JSON: a non-finite number (which
 * JSONEncoder rejects) or a non-integral Swift `Int` throws instead of
 * producing a file the Mac could not load.
 *
 * Locked to Swift by the `projectDecode` golden vectors (serialize(parse(x))
 * must equal Swift's encode(decode(x))) and by `--web-roundtrip-check`.
 */
import type {
  Annotation,
  BlurRegion,
  CameraLayoutRegion,
  CodableColor,
  CodablePoint,
  ExportSettings,
  ExtraKeys,
  FocusRegion,
  HighlightRegion,
  Project,
  ProjectSettings,
  ProjectSourceSegment,
  SubtitleSegment,
  TiltRegion,
  VideoClipSegment,
  VideoSpeedRegion,
  VoiceOverClip,
  WordTiming,
  ZoomRegion,
} from "./types";
import { PROJECT_SETTINGS_KEYS, PROJECT_SETTINGS_OPTIONAL_KEYS } from "./keys";

export interface SerializeOptions {
  /** Re-emit unknown keys preserved in `$extra` (default true). */
  includeExtra?: boolean;
}

export class ProjectEncodeError extends Error {
  constructor(path: string, message: string) {
    super(`${path}: ${message}`);
    this.name = "ProjectEncodeError";
  }
}

type Out = Record<string, unknown>;

class Encoder {
  constructor(private readonly includeExtra: boolean) {}

  num(v: number, path: string): number {
    if (typeof v !== "number" || !Number.isFinite(v)) {
      throw new ProjectEncodeError(path, `cannot encode non-finite/invalid Double ${String(v)}`);
    }
    return v;
  }

  int(v: number, path: string): number {
    if (typeof v !== "number" || !Number.isInteger(v)) {
      throw new ProjectEncodeError(path, `Swift Int field holds non-integer ${String(v)}`);
    }
    return v;
  }

  finish(out: Out, extra: ExtraKeys | undefined): Out {
    if (this.includeExtra && extra) {
      for (const [k, v] of Object.entries(extra)) {
        if (!(k in out)) out[k] = v;
      }
    }
    return out;
  }

  color(c: CodableColor, path: string): Out {
    return this.finish(
      {
        red: this.num(c.red, `${path}.red`),
        green: this.num(c.green, `${path}.green`),
        blue: this.num(c.blue, `${path}.blue`),
        opacity: this.num(c.opacity, `${path}.opacity`),
      },
      c.$extra,
    );
  }

  point(p: CodablePoint, path: string): Out {
    return this.finish({ x: this.num(p.x, `${path}.x`), y: this.num(p.y, `${path}.y`) }, p.$extra);
  }

  exportSettings(s: ExportSettings, path: string): Out {
    return this.finish(
      {
        format: s.format,
        resolution: s.resolution,
        fps: this.int(s.fps, `${path}.fps`),
        quality: this.num(s.quality, `${path}.quality`),
        customWidth: this.int(s.customWidth, `${path}.customWidth`),
        customHeight: this.int(s.customHeight, `${path}.customHeight`),
        collapseStaticSpans: s.collapseStaticSpans,
      },
      s.$extra,
    );
  }

  /** Generic field encoder for ProjectSettings (types are uniform per value). */
  private settingsValue(key: string, v: unknown, path: string): unknown {
    if (typeof v === "number") return this.num(v, path);
    if (typeof v === "boolean" || typeof v === "string") return v;
    if (v === null) return null;
    if (key === "exportSettings") return this.exportSettings(v as ExportSettings, path);
    if (typeof v === "object") return this.color(v as CodableColor, path);
    throw new ProjectEncodeError(path, `unexpected value ${String(v)}`);
  }

  settings(s: ProjectSettings, path: string): Out {
    const out: Out = {};
    const record = s as unknown as Record<string, unknown>;
    for (const key of PROJECT_SETTINGS_KEYS) {
      const v = record[key];
      if (PROJECT_SETTINGS_OPTIONAL_KEYS.has(key)) {
        // encodeIfPresent — omit when nil.
        if (v === undefined || v === null) continue;
      } else if (key === "backgroundImagePath") {
        // c.encode(Optional<String>) — JSON null when nil.
        out[key] = v === undefined || v === null ? null : v;
        continue;
      } else if (v === undefined) {
        throw new ProjectEncodeError(`${path}.${key}`, "missing required settings field");
      }
      out[key] = this.settingsValue(key, v, `${path}.${key}`);
    }
    return this.finish(out, s.$extra);
  }

  zoomRegion(r: ZoomRegion, path: string): Out {
    const out: Out = {
      id: r.id,
      startTime: this.num(r.startTime, `${path}.startTime`),
      endTime: this.num(r.endTime, `${path}.endTime`),
      zoomLevel: this.num(r.zoomLevel, `${path}.zoomLevel`),
      // CGPoint's Codable is an unkeyed [x, y].
      focalPoint: [this.num(r.focalPoint.x, `${path}.focalPoint.x`), this.num(r.focalPoint.y, `${path}.focalPoint.y`)],
    };
    if (r.animationStyle !== undefined) out.animationStyle = r.animationStyle;
    if (r.cardOffsetX !== undefined) out.cardOffsetX = this.num(r.cardOffsetX, `${path}.cardOffsetX`);
    if (r.cardOffsetY !== undefined) out.cardOffsetY = this.num(r.cardOffsetY, `${path}.cardOffsetY`);
    if (r.followsCursor !== undefined) out.followsCursor = r.followsCursor;
    if (r.isAuto !== undefined) out.isAuto = r.isAuto;
    return this.finish(out, r.$extra);
  }

  tiltRegion(r: TiltRegion, path: string): Out {
    const out: Out = {
      id: r.id,
      startTime: this.num(r.startTime, `${path}.startTime`),
      endTime: this.num(r.endTime, `${path}.endTime`),
      pitch: this.num(r.pitch, `${path}.pitch`),
      yaw: this.num(r.yaw, `${path}.yaw`),
      roll: this.num(r.roll, `${path}.roll`),
    };
    if (r.animationStyle !== undefined) out.animationStyle = r.animationStyle;
    return this.finish(out, r.$extra);
  }

  private rect(out: Out, r: { x: number; y: number; width: number; height: number }, path: string): Out {
    out.rectX = this.num(r.x, `${path}.rect.x`);
    out.rectY = this.num(r.y, `${path}.rect.y`);
    out.rectW = this.num(r.width, `${path}.rect.width`);
    out.rectH = this.num(r.height, `${path}.rect.height`);
    return out;
  }

  blurRegion(r: BlurRegion, path: string): Out {
    const out: Out = {
      id: r.id,
      startTime: this.num(r.startTime, `${path}.startTime`),
      endTime: this.num(r.endTime, `${path}.endTime`),
      label: r.label,
      intensity: this.num(r.intensity, `${path}.intensity`),
      style: r.style,
      animated: r.animated,
    };
    return this.finish(this.rect(out, r.rect, path), r.$extra);
  }

  highlightRegion(r: HighlightRegion, path: string): Out {
    const out: Out = {
      id: r.id,
      startTime: this.num(r.startTime, `${path}.startTime`),
      endTime: this.num(r.endTime, `${path}.endTime`),
      label: r.label,
      opacity: this.num(r.opacity, `${path}.opacity`),
    };
    return this.finish(this.rect(out, r.rect, path), r.$extra);
  }

  focusRegion(r: FocusRegion, path: string): Out {
    const out: Out = {
      id: r.id,
      startTime: this.num(r.startTime, `${path}.startTime`),
      endTime: this.num(r.endTime, `${path}.endTime`),
      label: r.label,
      intensity: this.num(r.intensity, `${path}.intensity`),
      falloff: this.num(r.falloff, `${path}.falloff`),
      style: r.style,
      angle: this.num(r.angle, `${path}.angle`),
      cornerRadius: this.num(r.cornerRadius, `${path}.cornerRadius`),
    };
    return this.finish(this.rect(out, r.rect, path), r.$extra);
  }

  cameraLayoutRegion(r: CameraLayoutRegion, path: string): Out {
    return this.finish(
      {
        id: r.id,
        startTime: this.num(r.startTime, `${path}.startTime`),
        endTime: this.num(r.endTime, `${path}.endTime`),
        mode: r.mode,
      },
      r.$extra,
    );
  }

  annotation(a: Annotation, path: string): Out {
    const out: Out = {
      id: a.id,
      type: a.type,
      startTime: this.num(a.startTime, `${path}.startTime`),
      endTime: this.num(a.endTime, `${path}.endTime`),
      x: this.num(a.x, `${path}.x`),
      y: this.num(a.y, `${path}.y`),
      arrowEndX: this.num(a.arrowEndX, `${path}.arrowEndX`),
      arrowEndY: this.num(a.arrowEndY, `${path}.arrowEndY`),
      text: a.text,
      fontSize: this.num(a.fontSize, `${path}.fontSize`),
      showBackground: a.showBackground,
      color: this.color(a.color, `${path}.color`),
      backgroundColor: this.color(a.backgroundColor, `${path}.backgroundColor`),
      lineWidth: this.num(a.lineWidth, `${path}.lineWidth`),
      drawingStrokes: a.drawingStrokes.map((stroke, i) =>
        stroke.map((p, j) => this.point(p, `${path}.drawingStrokes[${i}][${j}]`)),
      ),
      fontWeight: a.fontWeight,
      uppercase: a.uppercase,
    };
    if (a.fontName !== undefined) out.fontName = a.fontName;
    out.opacity = this.num(a.opacity, `${path}.opacity`);
    out.cornerRadius = this.num(a.cornerRadius, `${path}.cornerRadius`);
    out.animatesIn = a.animatesIn;
    out.showShadow = a.showShadow;
    out.enterEffect = a.enterEffect;
    out.exitEffect = a.exitEffect;
    out.backdropOpacity = this.num(a.backdropOpacity, `${path}.backdropOpacity`);
    return this.finish(out, a.$extra);
  }

  voiceOverClip(c: VoiceOverClip, path: string): Out {
    return this.finish(
      {
        id: c.id,
        fileName: c.fileName,
        startTime: this.num(c.startTime, `${path}.startTime`),
        sourceStartTime: this.num(c.sourceStartTime, `${path}.sourceStartTime`),
        duration: this.num(c.duration, `${path}.duration`),
        sourceDuration: this.num(c.sourceDuration, `${path}.sourceDuration`),
        gain: this.num(c.gain, `${path}.gain`),
        label: c.label,
      },
      c.$extra,
    );
  }

  word(w: WordTiming, path: string): Out {
    return this.finish(
      {
        id: w.id,
        startTime: this.num(w.startTime, `${path}.startTime`),
        endTime: this.num(w.endTime, `${path}.endTime`),
        text: w.text,
      },
      w.$extra,
    );
  }

  subtitle(s: SubtitleSegment, path: string): Out {
    return this.finish(
      {
        id: s.id,
        startTime: this.num(s.startTime, `${path}.startTime`),
        endTime: this.num(s.endTime, `${path}.endTime`),
        text: s.text,
        words: s.words.map((w, i) => this.word(w, `${path}.words[${i}]`)),
      },
      s.$extra,
    );
  }

  speedRegion(r: VideoSpeedRegion, path: string): Out {
    return this.finish(
      {
        id: r.id,
        startTime: this.num(r.startTime, `${path}.startTime`),
        endTime: this.num(r.endTime, `${path}.endTime`),
        speed: this.num(r.speed, `${path}.speed`),
      },
      r.$extra,
    );
  }

  clip(c: VideoClipSegment, path: string): Out {
    return this.finish(
      {
        id: c.id,
        startTime: this.num(c.startTime, `${path}.startTime`),
        endTime: this.num(c.endTime, `${path}.endTime`),
      },
      c.$extra,
    );
  }

  sourceSegment(s: ProjectSourceSegment, path: string): Out {
    return this.finish(
      {
        startTime: this.num(s.startTime, `${path}.startTime`),
        duration: this.num(s.duration, `${path}.duration`),
        kind: s.kind,
        contentX: this.num(s.contentX, `${path}.contentX`),
        contentY: this.num(s.contentY, `${path}.contentY`),
        contentWidth: this.num(s.contentWidth, `${path}.contentWidth`),
        contentHeight: this.num(s.contentHeight, `${path}.contentHeight`),
      },
      s.$extra,
    );
  }

  project(p: Project): Out {
    const out: Out = {
      id: p.id,
      name: p.name,
      createdAt: this.num(p.createdAt, "createdAt"),
      videoURL: p.videoURL ?? null,
      cursorDataURL: p.cursorDataURL ?? null,
    };
    if (p.keystrokeDataURL !== undefined) out.keystrokeDataURL = p.keystrokeDataURL;
    out.cameraVideoURL = p.cameraVideoURL ?? null;
    out.cameraTimeOffset = this.num(p.cameraTimeOffset, "cameraTimeOffset");
    out.settings = this.settings(p.settings, "settings");
    out.zoomRegions = p.zoomRegions.map((r, i) => this.zoomRegion(r, `zoomRegions[${i}]`));
    out.tiltRegions = p.tiltRegions.map((r, i) => this.tiltRegion(r, `tiltRegions[${i}]`));
    out.blurRegions = p.blurRegions.map((r, i) => this.blurRegion(r, `blurRegions[${i}]`));
    out.highlightRegions = p.highlightRegions.map((r, i) => this.highlightRegion(r, `highlightRegions[${i}]`));
    out.focusRegions = p.focusRegions.map((r, i) => this.focusRegion(r, `focusRegions[${i}]`));
    out.cameraLayoutRegions = p.cameraLayoutRegions.map((r, i) =>
      this.cameraLayoutRegion(r, `cameraLayoutRegions[${i}]`),
    );
    out.annotations = p.annotations.map((a, i) => this.annotation(a, `annotations[${i}]`));
    out.voiceOverClips = p.voiceOverClips.map((c, i) => this.voiceOverClip(c, `voiceOverClips[${i}]`));
    out.subtitles = p.subtitles.map((s, i) => this.subtitle(s, `subtitles[${i}]`));
    out.speedRegions = p.speedRegions.map((r, i) => this.speedRegion(r, `speedRegions[${i}]`));
    out.splitPoints = p.splitPoints.map((t, i) => this.num(t, `splitPoints[${i}]`));
    out.videoClipSegments = p.videoClipSegments.map((c, i) => this.clip(c, `videoClipSegments[${i}]`));
    out.duration = this.num(p.duration, "duration");
    out.trimStart = this.num(p.trimStart, "trimStart");
    out.trimEnd = this.num(p.trimEnd, "trimEnd");
    out.recordingSourceKind = p.recordingSourceKind;
    if (p.recordedAppBundleID !== undefined) out.recordedAppBundleID = p.recordedAppBundleID;
    out.sourceSegments = p.sourceSegments.map((s, i) => this.sourceSegment(s, `sourceSegments[${i}]`));
    if (p.reminderDate !== undefined) out.reminderDate = this.num(p.reminderDate, "reminderDate");
    out.isStillCapture = p.isStillCapture;
    out.stillTreatment = p.stillTreatment;
    return this.finish(out, p.$extra);
  }
}

/** The project as the JSON object Swift's `encode(to:)` produces (+ `$extra`). */
export function serializeProject(p: Project, options: SerializeOptions = {}): Record<string, unknown> {
  return new Encoder(options.includeExtra ?? true).project(p);
}

/** project.json text (2-space pretty print, like the Mac's `.prettyPrinted`).
 * Unlike `JSON.stringify`, keeps the sign of `-0` (Swift writes `-0`, and
 * e.g. a `-0` trim start changes `String(format:"%.6f")` → legacy clip ids). */
export function serializeProjectText(p: Project, options: SerializeOptions = {}): string {
  return stringifyJSON(serializeProject(p, options), 2);
}

/** JSON text with `-0` preserved; otherwise identical to JSON.stringify. */
export function stringifyJSON(value: unknown, indent = 0): string {
  const pad = (depth: number) => (indent > 0 ? "\n" + " ".repeat(indent * depth) : "");
  const sep = indent > 0 ? ": " : ":";
  const write = (v: unknown, depth: number): string => {
    if (typeof v === "number") return Object.is(v, -0) ? "-0" : JSON.stringify(v);
    if (v === null || typeof v !== "object") return JSON.stringify(v) ?? "null";
    if (Array.isArray(v)) {
      if (v.length === 0) return "[]";
      return `[${v.map((x) => pad(depth + 1) + write(x === undefined ? null : x, depth + 1)).join(",")}${pad(depth)}]`;
    }
    const entries = Object.entries(v as Record<string, unknown>).filter(([, x]) => x !== undefined);
    if (entries.length === 0) return "{}";
    return `{${entries.map(([k, x]) => `${pad(depth + 1)}${JSON.stringify(k)}${sep}${write(x, depth + 1)}`).join(",")}${pad(depth)}}`;
  };
  return write(value, 0);
}
