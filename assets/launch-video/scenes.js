// Shared scene manifest: read by index.html (window.SCENEKIT) and by the node
// scripts (require). `dur` is the minimum real length; a scene stretches to fit
// its voice-over line. `title` words land on screen exactly when the voice says
// them (matched against the ElevenLabs word timings). `clicks` are design-time
// (pre-SPEED) local seconds for the click SFX.
(function (root) {
  const SCENES = [
    { id: 's1', dark: true, dur: 2.2, clicks: [1.95],
      title: 'Hit record.', vo: 'So, you hit record,' },
    { id: 's2', dur: 2.4, clicks: [],
      title: 'It edits itself.', vo: 'and honestly? That\'s the whole job. It edits itself.' },
    { id: 's3', dur: 3.4, clicks: [1.75],
      title: 'Click. It zooms.', vo: 'Click something, and it zooms in for you.' },
    { id: 's5', dur: 3.2, clicks: [],
      title: 'Captions just show up.', vo: 'Captions just show up, and they\'re made on your device, not on some server.' },
    { id: 's6', dur: 3.4, clicks: [1.1, 2.1],
      title: 'Background. Corners. Tilt.', vo: 'Want it to look nice? Pick a background, round the corners, tilt it a little.' },
    { id: 's7', dur: 3.2, clicks: [1.0],
      title: 'Camera in the corner.', vo: 'Pop your camera in the corner, and talk over it if you want.' },
    { id: 's8', dur: 3.4, clicks: [1.6],
      title: 'Trim. Draw. Shortcuts.', vo: 'Then trim the boring bits, draw an arrow, show your shortcuts.' },
    { id: 's9', dur: 3.6, clicks: [],
      title: 'Same project, in your browser.', vo: 'Not on a Mac? The same project opens right in your browser.' },
    { id: 's10', dur: 3.4, clicks: [0.8, 3.1],
      title: 'Export it. Or send a link.', vo: 'When you\'re done, export it, or just send a link.' },
    { id: 's11', dur: 3.6, clicks: [],
      title: 'Ask Claude to do the editing.', vo: 'You can even ask Claude to do the editing. Which, yeah, is a little wild.' },
    { id: 's13', dark: true, dur: 4.0, clicks: [],
      title: 'Open source now.', vo: 'Oh, and one more thing. It\'s open source now. Fork it, change it, host it yourself, whatever you like.' },
    { id: 's14', dark: true, dur: 3.2, clicks: [],
      title: '', vo: 'That\'s CaptureCat. Go make something cool.' },
  ];
  // Scene choreography is authored in "design seconds"; it plays SPEED x faster.
  const SPEED = 1.3;
  // Transition overlap between consecutive scenes (a fast punch, not a fade).
  const XF = 0.22;

  // fps: both platforms take 60; frames are rendered at exact t = i / fps (CFR).
  // enc: YouTube wants closed GOPs at half the frame rate; X caps bitrate (~25 Mbps).
  const FORMATS = {
    youtube: { width: 1920, height: 1080, fps: 60, endHold: 5,
      enc: ['-profile:v', 'high', '-level:v', '4.2', '-crf', '16', '-g', '30', '-bf', '2', '-flags', '+cgop'] },
    x: { width: 1080, height: 1080, fps: 60, endHold: 0,
      enc: ['-profile:v', 'high', '-level:v', '4.2', '-crf', '18', '-maxrate', '16M', '-bufsize', '32M', '-g', '60', '-bf', '2'] },
  };

  // The voice is one continuous take, played unbroken from VO_AT seconds in. Scene i
  // starts where its line starts in the take (cut at the breath before it), so the
  // edit follows the read instead of the read waiting on the edit. Each scene plays
  // its authored choreography (dur * SPEED design seconds) squeezed to fit if its
  // line is short, at normal SPEED (then holding) if it's long.
  const VO_AT = 0.35, END_TAIL = 0.7;
  function buildTimeline(vo, fmt = 'youtube') {
    const endHold = (FORMATS[fmt] || FORMATS.youtube).endHold;
    const take = vo && vo.scenes ? vo : null;
    const starts = SCENES.map((s, i) => take ? (i === 0 ? 0 : VO_AT + take.scenes[s.id].t0) : null);
    let t = 0;
    const scenes = SCENES.map((s, i) => {
      let dur;
      if (take) {
        const last = i === SCENES.length - 1;
        dur = (last ? VO_AT + take.duration + END_TAIL : starts[i + 1]) - starts[i] + (last ? endHold : 0);
        t = starts[i];
      } else {
        // no recorded take yet: authored lengths, for previews
        dur = s.dur + (i === SCENES.length - 1 ? endHold : 0);
      }
      const speed = Math.max(SPEED, (s.dur * SPEED) / Math.max(0.5, dur - (i === SCENES.length - 1 ? endHold : 0)));
      const out = { id: s.id, start: t, dur, speed, clicks: s.clicks.map((c) => t + c / speed) };
      if (!take) t += dur;
      return out;
    });
    const total = take ? scenes[scenes.length - 1].start + scenes[scenes.length - 1].dur + XF : t + XF;
    return { fmt, scenes, total, xf: XF, voice: take ? { file: take.take, at: VO_AT } : null };
  }

  const api = { SCENES, FORMATS, SPEED, XF, VO_AT, buildTimeline };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  else root.SCENEKIT = api;
})(typeof window !== 'undefined' ? window : globalThis);
