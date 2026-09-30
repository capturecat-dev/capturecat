/**
 * TimelineCanvasMetrics + TimelineViewController layout constants — one
 * source of numbers for drawing AND hit testing (Y-down, CSS px = pt).
 */
export const M = {
  rulerHeight: 22,
  rulerBottomSpacing: 6,
  trackHeight: 48,
  trackSpacing: 4,
  bottomInset: 12,

  videoLaneY: 28,
  voiceLaneY: 80,
  effectsLaneY: 132,
  focusLaneY: 184,
  annotateLaneY: 236,
  tracksBottom: 284,

  subRowGap: 4,
  subRowPitch: 52,
  maxEffectsRows: 3,

  blockInset: 3,
  blockCornerRadius: 9,
  handleWidth: 8,
  minBlockWidth: 20,
  minDuration: 0.5,
  dragThreshold: 3,
  playheadStripHalfWidth: 14,

  // VIDEO row (VideoTrackRowNative)
  videoCorner: 8,
  videoHandleWidth: 12,
  videoMinBlockWidth: 40,
  videoMuteTrailingInset: 18,

  // VOICE row (VoiceTrackRowNative)
  voiceHandleWidth: 8,
  voiceMinBlockWidth: 52,
  voiceCorner: 6,
  voiceMinDuration: 0.25,
  voiceWaveHeight: 16,
  voiceVerticalPadding: 8,
  voiceHorizontalPadding: 10,

  // Panel chrome (TimelineViewController)
  labelWidth: 84,
  toolbarHeight: 42,
  canvasTopGap: 10,
  panelBottomGap: 8,
  canvasInsetX: 12,

  minScale: 1,
  maxScale: 30,
} as const;

/** Canvas area height for a given EFFECTS sub-row count (timelineCanvasHeight). */
export function canvasAreaHeight(effectsRows: number): number {
  const tracks = 5 * M.trackHeight + 4 * M.trackSpacing + (Math.max(1, effectsRows) - 1) * M.subRowPitch;
  return M.rulerHeight + M.rulerBottomSpacing + tracks + M.bottomInset;
}

/** The whole timeline panel's height (intrinsicPanelHeight): 42 + 10 + canvas + 8. */
export function panelHeight(effectsRows: number): number {
  return M.toolbarHeight + M.canvasTopGap + canvasAreaHeight(effectsRows) + M.panelBottomGap;
}
