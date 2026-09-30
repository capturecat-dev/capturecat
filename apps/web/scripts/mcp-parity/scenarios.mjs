/**
 * The op sequences the parity runner drives through BOTH the real Mac MCP
 * server and the web TS cores. Each scenario starts from a throwaway copy of
 * a synthetic parity fixture (optionally mutated into a variant) and runs its
 * steps in order against that one project; every step's result/error text
 * and the resulting project.json are compared.
 *
 * Step = [tool, args] (the runner adds `id`). Tools: every batchable edit
 * op, apply_edits, describe_project, get_transcript, style_options, undo.
 */

const Z = (n) => `00000000-0000-4000-8000-${String(n).padStart(12, "0")}`;
const LONG = (n, unit = "x") => unit.repeat(n);

// ── Synthetic sidecars ──────────────────────────────────────────────────────

/** Cursor stream with moves, dwell (idle) spans, discrete clicks, a drag and a
 * press-run that jitters under the drag threshold. 20 Hz, `seconds` long. */
export function syntheticCursor(seconds, { width = 1920, height = 1080 } = {}) {
  const events = [];
  const clickAt = new Set([9.0, 9.1, 26.0, 26.05, 31.0, 31.5, 32.4]);
  let x = 400;
  let y = 300;
  for (let i = 0; i <= seconds * 20; i++) {
    const t = i / 20;
    const moving = t < 1 || (t >= 9 && t < 10) || (t >= 25 && t < 25.5) || (t >= 31 && t < 33);
    if (moving) {
      x += 13.7;
      y += 4.1 * Math.sin(t * 3);
    }
    let isClick = [...clickAt].some((c) => Math.abs(c - t) < 1e-9);
    // A drag: a 0.4 s press run that travels ~120 pt (dropped as a click).
    if (t >= 20 && t < 20.4) {
      isClick = true;
      x += 30;
    }
    // A jittery press run that stays under the drag threshold (one click).
    if (t >= 14 && t < 14.3) {
      isClick = true;
      x += 1.5;
    }
    events.push({ timestamp: t, x, y, isClick });
  }
  return { version: 2, coordinateWidth: width, coordinateHeight: height, events };
}

export function syntheticKeys() {
  return {
    version: 1,
    events: [
      { timestamp: 4.0, category: "key" },
      { timestamp: 4.2, category: "space" },
      { timestamp: 11.5, category: "scroll" },
      { timestamp: 17.25, category: "return", shortcut: "⌘S", frontmostBundleID: "com.apple.TextEdit" },
      { timestamp: 27.0, category: "delete" },
      { timestamp: 2.0, category: "modifier" },
    ],
  };
}

/** 8 kHz mono s16 PCM pattern (see the runner's audio fixture). */
export function syntheticAudioSamples(seconds = 30, rate = 8000) {
  const out = new Int16Array(seconds * rate);
  let seed = 12345;
  const noise = () => {
    seed = (seed * 1103515245 + 12345) & 0x7fffffff;
    return seed / 0x7fffffff - 0.5;
  };
  for (let i = 0; i < out.length; i++) {
    const t = i / rate;
    let v = 0;
    const tone = (amp) => amp * Math.sin(2 * Math.PI * 440 * t);
    if (t < 2) v = tone(0.3);
    else if (t >= 7 && t < 7.05) v = tone(0.5); // one 50 ms blip inside silence
    else if (t >= 12 && t < 14) v = tone(0.25);
    else if (t >= 14.6 && t < 16) v = tone(0.2);
    else if (t >= 16 && t < 22) v = noise() * 0.002; // ≈ −60 dBFS hiss: still "silent"
    else if (t >= 22 && t < 23) v = tone(0.4);
    out[i] = Math.max(-32768, Math.min(32767, Math.round(v * 32767)));
  }
  return out;
}

// ── Scenarios ───────────────────────────────────────────────────────────────

export function buildScenarios() {
  const scenarios = [];

  // 1. The EFFECTS lane: add/update/remove zoom, tilt and linked zoomtilt.
  scenarios.push({
    name: "effects-lane",
    fixture: "05-tilt-regions",
    steps: [
      ["describe_project", {}],
      ["add_effect", {}],
      ["add_effect", { type: "pan", start: 0.2, end: 1 }],
      ["add_effect", { type: "zoom" }],
      ["add_effect", { type: "zoom", start: "1", end: 2 }],
      ["add_effect", { type: "zoom", start: true, end: 2 }],
      ["add_effect", { type: "zoom", start: -1, end: 1 }],
      ["add_effect", { type: "zoom", start: 2, end: 1 }],
      ["add_effect", { type: "zoom", start: 4.9, end: 5.2 }],
      ["add_effect", { type: "zoom", start: 4.9, end: 5.0009 }],
      ["add_effect", { type: "zoom", start: 0.2, end: 1.0, animationStyle: "Fast" }],
      ["add_effect", { type: "zoom", start: 0.2, end: 1.0, animationStyle: ["Snappy"] }],
      ["add_effect", { type: "zoom", start: 1.5, end: 2.5 }],
      [
        "add_effect",
        {
          type: "zoom",
          start: 0.2,
          end: 1.2,
          zoomLevel: 9,
          focalX: 1.4,
          focalY: -0.2,
          offsetX: 0.003,
          offsetY: 2.5,
          followsCursor: false,
          animationStyle: "Snappy",
        },
      ],
      ["add_effect", { type: "tilt", start: 1.2, end: 1.8, pitch: 99, yaw: -99, roll: 45 }],
      ["add_effect", { type: "zoomtilt", start: 4.4, end: 5.0, animationStyle: null, zoomLevel: 0.1, pitch: -10 }],
      ["add_effect", { type: "zoomtilt", start: 4.5, end: 4.9 }],
      ["update_effect", {}],
      ["update_effect", { at: "1" }],
      ["update_effect", { at: 0.1 }],
      ["update_effect", { at: 0.7, zoomLevel: 3, focalX: 0.25 }],
      ["update_effect", { at: 1.2, animationStyle: "Smooth", zoomLevel: "x" }],
      ["update_effect", { at: 1.5, pitch: 30, start: 1.3, end: 1.75 }],
      ["update_effect", { at: 4.6, zoomLevel: 2.5, pitch: 12, roll: -40, animationStyle: "Cinematic" }],
      ["update_effect", { at: 4.6, start: 4.45, end: 4.95 }],
      ["update_effect", { at: 4.7, start: 3.0, end: 4.9 }],
      ["update_effect", { at: 4.7, end: 5.5 }],
      ["update_effect", { at: 4.7, start: null }],
      ["update_effect", { at: 3.9, offsetX: -0.4, offsetY: 0.001, followsCursor: true, animationStyle: null }],
      ["update_effect", { at: 3.9, offsetX: -3, followsCursor: 0 }],
      ["update_effect", { at: 4.7, animationStyle: "Bogus" }],
      ["update_effect", { at: 2.5, yaw: 15, roll: -5, focalX: 0.9 }],
      ["remove_effect", {}],
      ["remove_effect", { at: 0.05 }],
      ["remove_effect", { at: 4.7 }],
      ["remove_effect", { at: 1.8 }],
      ["describe_project", {}],
      ["undo", {}],
      ["undo", { steps: 2 }],
      ["undo", { steps: 0 }],
      ["undo", { steps: 1.5 }],
      ["undo", { steps: "2" }],
      ["undo", { steps: 999 }],
      ["describe_project", {}],
    ],
  });

  // 2. Legacy overlapping effects: both-inside and near-linked pairs.
  scenarios.push({
    name: "effects-legacy-overlap",
    fixture: "05-tilt-regions",
    mutate(p) {
      p.zoomRegions = [
        { id: Z(9101), startTime: 0.5, endTime: 2.5, zoomLevel: 2, focalPoint: [0.3, 0.4] },
        { id: Z(9102), startTime: 3.0, endTime: 4.0, zoomLevel: 1.5, focalPoint: [0.5, 0.5], cardOffsetX: 0.2 },
      ];
      p.tiltRegions = [
        { id: Z(9201), startTime: 1.5, endTime: 3.0, pitch: 10, yaw: 0, roll: 0 },
        { id: Z(9202), startTime: 3.0004, endTime: 4.0004, pitch: -5, yaw: 3, roll: 1, animationStyle: "Instant" },
      ];
    },
    steps: [
      ["describe_project", {}],
      ["update_effect", { at: 2.0, pitch: 5, zoomLevel: 3 }],
      ["update_effect", { at: 3.0, yaw: 7 }],
      ["update_effect", { at: 3.5, zoomLevel: 1.2, pitch: 1, start: 3.2, end: 4.2 }],
      ["update_effect", { at: 1.0, start: 0.5, end: 1.6 }],
      ["remove_effect", { at: 2.0 }],
      ["remove_effect", { at: 3.7 }],
      ["describe_project", {}],
    ],
  });

  // 3. Annotations: every scriptable type, clamps, colours, effects, errors.
  const longText = "Lorem ipsum ".repeat(25);
  const combining = "é".repeat(210);
  scenarios.push({
    name: "annotations",
    fixture: "08-annotations",
    steps: [
      ["describe_project", {}],
      ["add_annotation", { type: "drawing", start: 1, end: 2 }],
      ["add_annotation", { type: "Text", start: 1, end: 2 }],
      ["add_annotation", { start: 1, end: 2 }],
      ["add_annotation", { type: "text" }],
      [
        "add_annotation",
        {
          type: "text",
          start: 1,
          end: 2,
          text: "Hello",
          color: "#FF3B30",
          backgroundColor: "#00000080",
          fontSize: 100,
          opacity: 0.1,
          enterEffect: "Drop",
          exitEffect: "Explode",
          showBackground: false,
        },
      ],
      ["add_annotation", { type: "arrow", start: 0.5, end: 1.5, x: 2, y: -1, arrowEndX: 0.9, lineWidth: 30 }],
      ["add_annotation", { type: "rectangle", start: 1, end: 3, backdropOpacity: 1.2, showBackground: 1 }],
      ["add_annotation", { type: "ellipse", start: 1, end: 3, lineWidth: -2, backdropOpacity: 0.4 }],
      ["add_annotation", { type: "tap", start: 2, end: 3, fontSize: 150 }],
      ["add_annotation", { type: "tap", start: 2, end: 3, fontSize: 5 }],
      ["add_annotation", { type: "callout", start: 0, end: 6, text: longText }],
      ["add_annotation", { type: "text", start: 0, end: 6, text: combining, fontSize: 5 }],
      ["add_annotation", { type: "text", start: 1, end: 2, color: "red" }],
      ["add_annotation", { type: "text", start: 1, end: 2, color: "#GGGGGG" }],
      ["add_annotation", { type: "text", start: 1, end: 2, color: "#FFF" }],
      ["add_annotation", { type: "text", start: 1, end: 2, backgroundColor: 12 }],
      ["add_annotation", { type: "text", start: 1, end: 2, text: 42 }],
      ["add_annotation", { type: "text", start: 1, end: 2, text: null }],
      ["add_annotation", { type: "text", start: 1, end: 2, enterEffect: "Spin" }],
      ["add_annotation", { type: "text", start: 1, end: 2, exitEffect: null }],
      ["add_annotation", { type: "text", start: 1, end: 2, exitEffect: { a: 1 } }],
      ["add_annotation", { type: "text", start: 1, end: 7 }],
      ["add_annotation", { type: "text", start: 1, end: 2, color: " #ff3b30cc\t" }],
      ["add_annotation", { type: "text", start: 1, end: 2, color: "+FFFFF", backgroundColor: "-00000" }],
      ["add_annotation", { type: "text", start: 1, end: 2, color: "FFFFFFFF", backgroundColor: "#12345678" }],
      ["update_annotation", {}],
      ["update_annotation", { annotationId: "nope" }],
      ["update_annotation", { annotationId: Z(999) }],
      ["update_annotation", { annotationId: Z(801).toLowerCase(), type: "arrow" }],
      ["update_annotation", { annotationId: Z(801).toLowerCase(), type: "text", start: 0.3 }],
      ["update_annotation", { annotationId: Z(801), start: 5.5 }],
      ["update_annotation", { annotationId: Z(803), text: "Look", x: 0.1, color: "#00FF00", arrowEndY: 3 }],
      ["update_annotation", { annotationId: Z(804), opacity: 0.5, enterEffect: "Draw On", exitEffect: "None" }],
      ["update_annotation", { annotationId: Z(807), fontSize: 10 }],
      ["update_annotation", { annotationId: Z(805), fontSize: 100, start: null, end: 5 }],
      ["update_annotation", { annotationId: Z(802), end: 7 }],
      ["update_annotation", { annotationId: Z(802), color: "#12" }],
      ["remove_annotation", { annotationId: Z(806) }],
      ["remove_annotation", { annotationId: Z(806) }],
      ["remove_annotation", { annotationId: 5 }],
      ["remove_annotation", {}],
      ["describe_project", {}],
      [
        "apply_edits",
        {
          ops: [
            { op: "add_annotation", args: { type: "text", start: 2, end: 4, text: "Batch" } },
            { op: "update_annotation", args: { annotationId: Z(801), text: "Updated in batch" } },
            { op: "remove_annotation", annotationId: Z(803) },
          ],
        },
      ],
      [
        "apply_edits",
        {
          ops: [
            { op: "add_annotation", args: { type: "arrow", start: 2, end: 4 } },
            { op: "update_annotation", args: { annotationId: Z(806), text: "gone" } },
          ],
        },
      ],
      ["undo", {}],
      ["describe_project", {}],
    ],
  });

  // 4. Privacy blur on the FOCUS lane (overlapping legacy blurs, focus,
  //    highlight) + every add_blur validation.
  scenarios.push({
    name: "blur-focus-lane",
    fixture: "09-blur-highlight-focus",
    steps: [
      ["describe_project", {}],
      ["add_blur", {}],
      ["add_blur", { start: 0, end: 0.5 }],
      ["add_blur", { start: 0, end: 1, style: "Mosaic" }],
      ["add_blur", { start: 0, end: 1, style: 1 }],
      ["add_blur", { start: 0, end: 1, x: 100, y: 50, width: 200, height: 80 }],
      ["add_blur", { start: 0, end: 1, width: 0.03 }],
      ["add_blur", { start: 0, end: 1, x: 0.9, width: 0.2 }],
      ["add_blur", { start: 0, end: 1, x: -0.1 }],
      ["add_blur", { start: 0, end: 1, intensity: 2 }],
      ["add_blur", { start: 0, end: 1, intensity: "0.5" }],
      ["add_blur", { start: 0, end: 1, intensity: null }],
      ["add_blur", { start: 0, end: 1 }],
      ["add_blur", { start: 4.4, end: 5.3 }],
      ["remove_blur", {}],
      ["remove_blur", { blurId: "abc" }],
      ["remove_blur", { blurId: Z(1) }],
      ["remove_blur", { blurId: Z(901) }],
      [
        "add_blur",
        {
          start: 0.2,
          end: 1.2,
          style: "Pixelate",
          label: "API key " + LONG(80, "k"),
          x: 0.1,
          y: 0.1,
          width: 0.9,
          height: 0.9001,
          animated: true,
          intensity: 0.1,
        },
      ],
      ["add_blur", { start: 0, end: 1 }],
      ["describe_project", {}],
      ["undo", {}],
      ["add_blur", { start: 0.2, end: 1.2, style: "Blur", label: 7, animated: 1 }],
      ["describe_project", {}],
    ],
  });

  // 5. Camera-layout regions occupy the FOCUS lane too.
  scenarios.push({
    name: "blur-vs-camera-layout",
    fixture: "13-camera-bubble-layouts",
    steps: [
      ["describe_project", {}],
      ["add_blur", { start: 1.5, end: 2.3 }],
      ["add_blur", { start: 2.4, end: 3.0, style: "Pixelate" }],
      ["add_blur", { start: 3.9, end: 4.8, x: 0, y: 0, width: 1, height: 1 }],
      ["set_style", { patch: { showCamera: true, cameraShape: "Squircle", cameraSize: 240, cameraBorderColor: "#FFFFFF" } }],
      ["style_options", { group: "camera" }],
      ["describe_project", {}],
    ],
  });

  // 6. Speed, trim and cut interactions on a trimmed, speed-ramped, cut take.
  scenarios.push({
    name: "speed-trim-cut",
    fixture: "12-speed-trim-clips",
    steps: [
      ["describe_project", {}],
      ["set_speed", {}],
      ["set_speed", { speed: "2", start: 1, end: 2 }],
      ["set_speed", { speed: 0.4, start: 1, end: 2 }],
      ["set_speed", { speed: 4.5, start: 1, end: 2 }],
      ["set_speed", { speed: 1.005, start: 1, end: 2 }],
      ["set_speed", { speed: 2 }],
      ["set_speed", { speed: 3, start: 1.005, end: 1.995 }],
      ["set_speed", { speed: 2, start: 4, end: 4.5 }],
      ["set_speed", { speed: 2, start: 1.5, end: 2.8 }],
      ["set_speed", { speed: 1.5, start: 4, end: 5 }],
      ["set_speed", { speed: 4, start: 5.2, end: 6 }],
      ["set_speed", { speed: 0.75, start: 0, end: 0.9 }],
      ["set_speed", { speed: 1.23456, start: 2.5, end: 3.5 }],
      ["set_speed", { speed: 1.23456, start: 2.05, end: 2.95 }],
      ["set_speed", { speed: 2, start: 2.5, end: 3.2 }],
      ["remove_speed", { at: 2.5 }],
      ["remove_speed", {}],
      ["remove_speed", { speedId: "x" }],
      ["remove_speed", { speedId: null, at: 3.2 }],
      ["remove_speed", { speedId: Z(77) }],
      ["remove_speed", { at: 3.2 }],
      ["remove_speed", { at: 10 }],
      ["remove_speed", { speedId: Z(1201).toLowerCase() }],
      ["set_trim", {}],
      ["set_trim", { start: -1 }],
      ["set_trim", { end: 7 }],
      ["set_trim", { start: 2, end: 2.3 }],
      ["set_trim", { start: 2.6, end: 3.1 }],
      ["set_trim", { start: 1 }],
      ["set_trim", { start: 0.8, end: null }],
      ["set_trim", { end: 5.9 }],
      ["set_trim", { reset: true }],
      ["set_trim", { reset: 1, start: 3 }],
      ["set_trim", { start: 0.5, end: 5.6004 }],
      ["set_trim", { start: 0.5, end: 6.0005 }],
      ["set_trim", { start: 0.5, end: 5.6 }],
      ["cut_video", {}],
      ["cut_video", { ranges: [] }],
      ["cut_video", { ranges: [{ start: 1, end: 0.5 }] }],
      ["cut_video", { ranges: [1, 2] }],
      ["cut_video", { ranges: [{ start: 1, end: 2 }, 3] }],
      ["cut_video", { ranges: [{ start: "1", end: 2 }] }],
      ["cut_video", { ranges: [{ start: 2.61, end: 3.09 }] }],
      ["cut_video", { ranges: [{ start: 1.0, end: 1.5 }] }],
      ["cut_video", { ranges: [{ start: 3.12, end: 3.14 }] }],
      ["cut_video", { ranges: [{ start: 4.0, end: 4.2 }, { start: 5.0, end: 5.5 }] }],
      ["cut_video", { ranges: [{ start: 0, end: 6 }] }],
      ["set_trim", { start: 1.1, end: 1.45 }],
      ["set_trim", { start: 1.0, end: 1.5 }],
      ["set_trim", { start: 0.9, end: 4.1 }],
      ["set_speed", { speed: 2, start: 1.5, end: 2.6 }],
      ["describe_project", {}],
      ["get_transcript", {}],
      ["undo", { steps: 3 }],
      ["describe_project", {}],
    ],
  });

  // 7. Legacy split points (no videoClipSegments): stable clip ids.
  scenarios.push({
    name: "legacy-split-points",
    fixture: "03-solid-square-rect",
    mutate(p) {
      p.splitPoints = [2.0, 1.0, 2.995];
      p.videoClipSegments = [];
      p.trimStart = 0.2;
    },
    steps: [
      ["describe_project", {}],
      ["set_trim", { end: 2.9 }],
      ["cut_video", { ranges: [{ start: 1.5, end: 1.7 }] }],
      ["describe_project", {}],
      ["set_trim", { reset: true }],
      ["cut_video", { ranges: [{ start: 0, end: 0.3 }, { start: 2.5, end: 3 }] }],
      ["describe_project", {}],
    ],
  });

  // 8. set_style across EVERY group, plus each validation kind.
  scenarios.push({
    name: "style-all-groups",
    fixture: "02-mesh-look-filters",
    mutate(p) {
      p.settings.videoCustomX = 0.3;
      p.settings.videoCustomY = 0.7;
    },
    steps: [
      ["style_options", {}],
      ["style_options", { group: 5 }],
      ["style_options", { group: "nope" }],
      ["set_style", {}],
      ["set_style", { patch: {} }],
      ["set_style", { patch: [] }],
      ["set_style", { patch: { bogus: 1 } }],
      ["set_style", { patch: { backgroundPadingg: 1 } }],
      ["set_style", { patch: { shadow: 1 } }],
      ["set_style", { patch: { CURSORTILT: 1 } }],
      ["set_style", { patch: { "": 1 } }],
      ["set_style", { patch: { aspectRatio: "1:1", zzz: 1 } }],
      [
        "set_style",
        {
          patch: {
            aspectRatio: "9:16",
            backgroundPadding: 64,
            videoPlacement: "Top Left",
            frameShape: "Squircle",
            cornerRadius: 20,
            windowCornerRadius: 0,
            shadowRadius: 60,
            shadowOpacity: 0.25,
            showDeviceFrame: false,
          },
        },
      ],
      [
        "set_style",
        {
          patch: {
            backgroundType: "Solid Color",
            gradientStartColor: "#112233",
            gradientEndColor: "#445566AA",
            gradientAngle: 90,
            solidColor: "#abcdef",
            backgroundBlur: 0.5,
            backgroundBrightness: -1,
            backgroundSaturation: 2,
            backgroundContrast: 0.5,
            backgroundHue: 360,
            backgroundTintColor: "#FF000080",
            backgroundTintOpacity: 0.3,
            backgroundVignette: 1,
            backgroundPixelate: 0.2,
            backgroundHalftone: 0.1,
            backgroundNoise: 0.05,
          },
        },
      ],
      [
        "set_style",
        {
          patch: {
            showCursor: false,
            cursorStyle: "Ring",
            cursorScale: 3,
            cursorFluidEnabled: 0,
            cursorTension: 20,
            cursorFriction: 80,
            cursorMass: 0.2,
            cursorTilt: 1,
            cursorStretch: 0.5,
            cursorDrag: 0.25,
            cursorWeight: 0.5,
            smoothCursor: true,
            smoothingFactor: 0.05,
            autoHideCursor: true,
            autoHideDelay: 10,
            cursorLoopToStart: true,
            cursorStopAtEnd: true,
          },
        },
      ],
      [
        "set_style",
        {
          patch: {
            showClickRipple: false,
            clickRippleColor: "#00FF0080",
            clickRippleSize: 100,
            clickSoundEnabled: true,
            clickSoundVolume: 0.1,
            clickSoundStyle: "Pop",
            keySoundEnabled: 1,
            keySoundVolume: 1,
            keySoundStyle: "Blue Click",
            showKeystrokes: false,
            keystrokeOverlayScopeToRecordedApp: false,
          },
        },
      ],
      [
        "set_style",
        {
          patch: {
            showCamera: true,
            cameraPosition: "Top Left",
            cameraShape: "Rounded Rectangle",
            cameraOrientation: "Vertical",
            cameraSize: 60,
            cameraMirrored: true,
            cameraBrightness: 1,
            cameraContrast: 1.5,
            cameraSaturation: 0,
            cameraHue: -180,
            cameraFilter: "Noir",
            cameraRingLight: 0.7,
            cameraCornerRadius: 60,
            cameraBorderWidth: 8,
            cameraBorderColor: "#FF00FF",
            cameraOpacity: 0.2,
            cameraTiltPitch: -25,
            cameraTiltYaw: 25,
            cameraTagText: "Mike — CaptureCat",
            cameraTagSubtext: "",
            cameraTagFontName: "Avenir Next",
            cameraTagTextColor: "#FFFFFF00",
            cameraTagBackgroundColor: "#00000000",
            cameraTagPosition: "Overlap Bottom",
          },
        },
      ],
      [
        "set_style",
        {
          patch: {
            menuBarReplacement: "Clean Dark",
            menuBarTitle: "Demo",
            menuBarTitleAlignment: "Center",
            menuBarShowStatusIcons: false,
            menuBarClock: "10:09 AM",
            menuBarHeight: 6,
          },
        },
      ],
      [
        "set_style",
        {
          patch: {
            animationSpeed: "Rapid",
            autoZoomLevel: 1.5,
            cameraFollowSpeed: 1,
            motionBlur: true,
            motionBlurStrength: 0.9,
            parallaxStrength: 0.4,
            screenTiltMode: "Both",
            screenTiltAngle: -60,
            screenTiltYaw: 60,
            screenTiltRoll: 30,
          },
        },
      ],
      [
        "set_style",
        {
          patch: {
            introSlideStyle: "Bottom",
            introSlideDuration: 0.3,
            introSlideStart: 3600,
            introSlideBounce: 1,
            introSlideSpeed: 4,
            curtainUnveilCorner: "Top Right",
            curtainUnveilDuration: 0.1,
            curtainUnveilStart: 0,
            curtainLogoOpacity: 0,
            curtainLogoScale: 0.8,
            curtainColor: "#101010",
            curtainLogoTint: "#EEEEEE80",
          },
        },
      ],
      [
        "set_style",
        { patch: { systemAudioVolume: 0, microphoneVolume: 0.5, voiceOverVolume: 1.5, muteRecordedAudio: true } },
      ],
      [
        "set_style",
        {
          patch: {
            showSubtitles: false,
            subtitleFontSize: 64,
            subtitlePosition: "Top",
            subtitleStyle: "Glow",
            subtitleWeight: "Heavy",
            subtitleUppercase: true,
          },
        },
      ],
      [
        "set_style",
        { patch: { showWatermark: true, watermarkOpacity: 0.1, watermarkSize: 400, watermarkX: 0, watermarkY: 0.5 } },
      ],
      ["style_options", {}],
      ["set_style", { patch: { cursorStopAtEnd: false, cursorLoopToStart: true } }],
      ["set_style", { patch: { aspectRatio: "16:10" } }],
      ["set_style", { patch: { aspectRatio: 169 } }],
      ["set_style", { patch: { backgroundPadding: 301 } }],
      ["set_style", { patch: { backgroundPadding: "12" } }],
      ["set_style", { patch: { backgroundPadding: true } }],
      ["set_style", { patch: { backgroundPadding: null } }],
      ["set_style", { patch: { backgroundPadding: -0.30000000000000004 } }],
      ["set_style", { patch: { backgroundPadding: 1e21 } }],
      ["set_style", { patch: { backgroundPadding: 123456789012345.67 } }],
      ["set_style", { patch: { backgroundPadding: [1, "a b", "abc", 2.5, null, true, [], { k: "v w" }] } }],
      ["set_style", { patch: { backgroundPadding: { b: 1, a: "x y", "é": [2], "": {} } } }],
      ["set_style", { patch: { gradientAngle: 360.5 } }],
      ["set_style", { patch: { smoothingFactor: 0.04 } }],
      ["set_style", { patch: { showCursor: 2 } }],
      ["set_style", { patch: { showCursor: "true" } }],
      ["set_style", { patch: { cameraTagText: LONG(61) } }],
      ["set_style", { patch: { cameraTagText: "\u{1F468}‍\u{1F469}‍\u{1F467}".repeat(60) } }],
      ["set_style", { patch: { cameraTagText: 5 } }],
      ["set_style", { patch: { cameraTagFontName: null } }],
      ["set_style", { patch: { menuBarClock: LONG(13, "9") } }],
      ["set_style", { patch: { solidColor: "#12345" } }],
      ["set_style", { patch: { solidColor: 0xffffff } }],
      ["set_style", { patch: { cameraBorderColor: "nope" } }],
      ["set_style", { patch: { videoPlacement: "Bottom Right" } }],
      ["style_options", { group: "cursor" }],
      ["style_options", { group: "canvas" }],
      ["describe_project", {}],
      ["undo", { steps: 4 }],
      ["style_options", { group: "background" }],
    ],
  });

  // 8b. Key ordering, no-project style_options, render_frames validation.
  scenarios.push({
    name: "style-misc-and-render-args",
    fixture: "07-intro-slide-curtain",
    steps: [
      ["style_options", { id: undefined }],
      ["style_options", { id: "", group: "intro" }],
      ["set_style", { patch: { "\u{1F600}": 1, "\uE000": 1 } }],
      ["set_style", { patch: { Z: 1, a: 1 } }],
      ["set_style", { patch: { zzz: 1, "é": 1 } }],
      ["set_style", { patch: { introSlideStyle: "Left", curtainUnveilCorner: "Bottom Left", curtainColor: "#000000" } }],
      ["render_frames", {}],
      ["render_frames", { layout: "grid", times: [1] }],
      ["render_frames", { format: "gif", times: [1] }],
      ["render_frames", { format: "JPEG", quality: 2, times: [1] }],
      ["render_frames", { quality: null, times: [1] }],
      ["render_frames", { times: [1], span: { start: 0 } }],
      ["render_frames", { times: [] }],
      ["render_frames", { times: [1, "2"] }],
      ["render_frames", { times: [0, 1, 2, 3, 4, 5, 6, 7, 8] }],
      ["render_frames", { layout: "contact_sheet", times: Array.from({ length: 17 }, (_, i) => i / 4) }],
      ["render_frames", { span: { count: 9 } }],
      ["render_frames", { layout: "contact_sheet", span: { count: 0.5 } }],
      ["render_frames", { layout: "contact_sheet", span: { count: 17 } }],
      ["render_frames", { span: { start: -1 } }],
      ["render_frames", { span: { start: 2, end: 2 } }],
      ["render_frames", { span: { start: 2, end: 1, count: 3 } }],
      ["render_frames", { span: "0-2" }],
      ["style_options", { group: "intro" }],
    ],
  });

  // 9. apply_edits: validation, flat entries, all-or-nothing, auto_zoom.
  const tooMany = Array.from({ length: 201 }, () => ({ op: "set_style", args: { patch: { cornerRadius: 1 } } }));
  scenarios.push({
    name: "apply-edits",
    fixture: "04-zoom-follow-motionblur",
    steps: [
      ["describe_project", {}],
      ["apply_edits", {}],
      ["apply_edits", { ops: [] }],
      ["apply_edits", { ops: "x" }],
      ["apply_edits", { ops: tooMany }],
      ["apply_edits", { ops: [5] }],
      ["apply_edits", { ops: [{ args: {} }] }],
      ["apply_edits", { ops: [{ op: 3 }] }],
      ["apply_edits", { ops: [{ op: "describe_project" }] }],
      ["apply_edits", { ops: [{ op: "toString" }] }],
      ["apply_edits", { ops: [{ op: "undo", args: {} }] }],
      [
        "apply_edits",
        {
          ops: [
            { op: "add_effect", args: { type: "tilt", start: 2.4, end: 3.0, id: "ignored" } },
            { op: "set_style", patch: { cornerRadius: 4, shadowOpacity: 0.8 } },
            { op: "update_effect", args: { at: 1, zoomLevel: 3, followsCursor: false } },
            { op: "set_speed", args: { speed: 2, start: 4.7, end: 5.9 } },
            { op: "set_trim", args: { start: 0.2, end: 5.9 } },
            { op: "add_annotation", args: { type: "tap", start: 1, end: 2, x: 0.3, y: 0.6 } },
            { op: "cut_video", args: { ranges: [{ start: 2.45, end: 2.95 }] } },
            { op: "add_blur", args: { start: 3, end: 4, label: "secret" } },
            { op: "remove_effect", args: { at: 2.7 } },
          ],
        },
      ],
      [
        "apply_edits",
        {
          ops: [
            { op: "add_effect", args: { type: "zoom", start: 5.0, end: 5.8 } },
            { op: "set_speed", args: { speed: 9, start: 1, end: 2 } },
          ],
        },
      ],
      ["apply_edits", { ops: [{ op: "remove_effect", args: { at: 0.1 } }, { op: "set_style", args: { patch: {} } }] }],
      [
        "apply_edits",
        {
          ops: [
            { op: "add_effect", args: { type: "zoom", start: 5.0, end: 5.8 } },
            { op: "add_effect", args: { type: "zoom", start: 5.2, end: 5.9 } },
          ],
        },
      ],
      ["apply_edits", { ops: [{ op: "set_trim", args: 5, start: 1 }] }],
      ["apply_edits", { ops: [{ op: "set_trim", args: null, reset: true }] }],
      ["auto_zoom", {}],
      ["describe_project", {}],
      ["auto_zoom", { zoomLevel: 3 }],
      ["apply_edits", { ops: [{ op: "auto_zoom", args: { zoomLevel: 1.8 } }, { op: "set_style", args: { patch: { autoZoomLevel: 2.5 } } }] }],
      ["describe_project", {}],
      ["undo", {}],
      ["undo", { steps: 2 }],
      ["describe_project", {}],
    ],
  });

  // 10. No cursor → auto_zoom refuses; still image → Motion tour.
  scenarios.push({
    name: "auto-zoom-no-cursor",
    fixture: "03-solid-square-rect",
    steps: [
      ["auto_zoom", {}],
      ["apply_edits", { ops: [{ op: "auto_zoom" }] }],
    ],
  });
  scenarios.push({
    name: "still-image-motion",
    fixture: "02-mesh-look-filters",
    mutate(p) {
      p.isStillCapture = true;
      p.duration = 8;
      p.zoomRegions = [
        { id: Z(9301), startTime: 0.5, endTime: 1.5, zoomLevel: 2, focalPoint: [0.5, 0.5], isAuto: true },
      ];
      p.tiltRegions = [{ id: Z(9302), startTime: 0.5, endTime: 1.5, pitch: 10, yaw: 0, roll: 0 }];
    },
    steps: [
      ["describe_project", {}],
      ["auto_zoom", {}],
      ["describe_project", {}],
      ["auto_zoom", { zoomLevel: 4 }],
      ["describe_project", {}],
    ],
  });

  // 11. Unprobed duration (0): unbounded spans, no output clock, no trim.
  scenarios.push({
    name: "unprobed-duration",
    fixture: "03-solid-square-rect",
    mutate(p) {
      p.duration = 0;
    },
    steps: [
      ["describe_project", {}],
      ["add_effect", { type: "zoom", start: 10, end: 100 }],
      ["set_trim", { start: 1 }],
      ["set_speed", { speed: 2, start: 1, end: 3 }],
      ["cut_video", { ranges: [{ start: 1, end: 2 }] }],
      ["apply_edits", { ops: [{ op: "add_blur", args: { start: 200, end: 300 } }] }],
      ["get_transcript", {}],
      ["describe_project", {}],
    ],
  });

  // 12. Transcript retiming through trim + speed; odd subtitles.
  scenarios.push({
    name: "transcript",
    fixture: "11-subtitles-ring-cursor",
    mutate(p) {
      p.subtitles.push(
        { id: Z(9401), startTime: 4.7, endTime: 4.8, text: "  \n\t ", words: [] },
        {
          id: Z(9402),
          startTime: 0.05,
          endTime: 0.19,
          text: "  " + "Long words ".repeat(60) + "\n",
          words: [
            { id: Z(9403), startTime: 0.05, endTime: 0.1, text: "W".repeat(100) },
            { id: Z(9404), startTime: 0.1, endTime: 0.19, text: "second" },
          ],
        },
      );
    },
    steps: [
      ["get_transcript", {}],
      ["describe_project", {}],
      ["set_trim", { start: 1, end: 4 }],
      ["get_transcript", {}],
      ["set_speed", { speed: 2, start: 1.2, end: 2.2 }],
      ["set_speed", { speed: 0.5, start: 3.0, end: 3.9 }],
      ["get_transcript", {}],
      ["set_trim", { start: 4.5, end: 5 }],
      ["get_transcript", {}],
      ["set_trim", { start: 0, end: 0.6 }],
      ["get_transcript", {}],
      ["describe_project", {}],
    ],
  });

  // 13. Pacing: synthetic cursor (dwells, clicks, a drag) + keystrokes on a
  //     silent (no audio track) recording.
  scenarios.push({
    name: "pacing-no-audio",
    fixture: "01-baseline-gradient",
    extraFiles: () => ({
      "cursor.json": JSON.stringify(syntheticCursor(40)),
      "keys.json": JSON.stringify(syntheticKeys()),
    }),
    mutate(p, dir, url) {
      p.duration = 40;
      p.keystrokeDataURL = url("keys.json");
    },
    steps: [
      ["describe_project", {}],
      ["set_trim", { start: 3, end: 30 }],
      ["describe_project", {}],
      ["set_speed", { speed: 3, start: 10.5, end: 24.5 }],
      ["describe_project", {}],
      ["set_trim", { reset: true }],
      ["describe_project", {}],
    ],
  });

  // 14. Legacy bare-array cursor file (coordinate size 0 → 1×1), no keys.
  scenarios.push({
    name: "pacing-legacy-cursor",
    fixture: "01-baseline-gradient",
    extraFiles: () => ({ "cursor.json": JSON.stringify(syntheticCursor(40).events) }),
    mutate(p) {
      p.duration = 40;
    },
    steps: [["describe_project", {}]],
  });

  // 15. A recording WITH audio: the RMS silence scan (8 kHz mono PCM .mov).
  scenarios.push({
    name: "pacing-audio-silence",
    fixture: "01-baseline-gradient",
    audio: true,
    extraFiles: () => ({
      "cursor.json": JSON.stringify(syntheticCursor(30)),
      "keys.json": JSON.stringify(syntheticKeys()),
    }),
    mutate(p, dir, url) {
      p.duration = 30;
      p.videoURL = url("recording-audio.mov");
      p.keystrokeDataURL = url("keys.json");
    },
    steps: [
      ["describe_project", {}],
      ["set_trim", { start: 1.5, end: 26 }],
      ["describe_project", {}],
    ],
  });

  // 16. Recording file missing: no audio keys at all.
  scenarios.push({
    name: "pacing-missing-video",
    fixture: "01-baseline-gradient",
    extraFiles: () => ({ "cursor.json": JSON.stringify(syntheticCursor(40)) }),
    mutate(p, dir, url) {
      p.duration = 40;
      p.videoURL = url("does-not-exist.mp4");
    },
    steps: [["describe_project", {}]],
  });

  // 16b. auto_zoom over a cursor stream with zoom-worthy activity (double
  //      click, dwell, typing), routing around a hand-placed zoom.
  scenarios.push({
    name: "auto-zoom-synthetic",
    fixture: "01-baseline-gradient",
    extraFiles: () => ({
      "cursor.json": JSON.stringify(syntheticCursor(40)),
      "keys.json": JSON.stringify({
        version: 1,
        events: [
          ...syntheticKeys().events,
          ...Array.from({ length: 12 }, (_, i) => ({ timestamp: 15 + i * 0.15, category: "key" })),
        ],
      }),
    }),
    mutate(p, dir, url) {
      p.duration = 40;
      p.trimEnd = 0;
      p.keystrokeDataURL = url("keys.json");
      p.zoomRegions = [{ id: Z(9501), startTime: 30, endTime: 32, zoomLevel: 1.7, focalPoint: [0.2, 0.8] }];
    },
    steps: [
      ["auto_zoom", {}],
      ["describe_project", {}],
      ["auto_zoom", { zoomLevel: 3 }],
      ["apply_edits", { ops: [{ op: "auto_zoom", args: { zoomLevel: 1.8 } }, { op: "update_effect", args: { at: 31, zoomLevel: 2 } }] }],
      ["set_style", { patch: { smoothCursor: true, smoothingFactor: 0.3 } }],
      ["auto_zoom", {}],
      ["describe_project", {}],
      ["undo", { steps: 2 }],
      ["describe_project", {}],
    ],
  });

  // 17. Undo history cap: 32 edits, only the newest 30 can be undone.
  scenarios.push({
    name: "undo-history-limit",
    fixture: "10-device-frame",
    steps: [
      ...Array.from({ length: 32 }, (_, i) => ["set_style", { patch: { cornerRadius: i % 21 } }]),
      ["undo", { steps: 31 }],
      ["undo", { steps: 30 }],
      ["undo", {}],
      ["describe_project", {}],
    ],
  });

  // 18. Read-only payloads on every fixture as shipped.
  for (const fixture of [
    "01-baseline-gradient",
    "02-mesh-look-filters",
    "03-solid-square-rect",
    "04-zoom-follow-motionblur",
    "05-tilt-regions",
    "06-cursor-hand-physics",
    "07-intro-slide-curtain",
    "08-annotations",
    "09-blur-highlight-focus",
    "10-device-frame",
    "11-subtitles-ring-cursor",
    "12-speed-trim-clips",
    "13-camera-bubble-layouts",
  ]) {
    scenarios.push({
      name: `read-only:${fixture}`,
      fixture,
      steps: [
        ["describe_project", {}],
        ["get_transcript", {}],
        ["style_options", {}],
      ],
    });
  }

  return scenarios;
}
