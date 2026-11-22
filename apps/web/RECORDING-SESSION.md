# One recording session for every clip on the site

Every image and video on the marketing site has to be the real app and a real
export. Nothing redrawn. You record the raw takes below in one sitting (about
15 minutes including setup). Claude then cuts, styles and exports every clip in
CaptureCat itself, and replaces the HTML recreations with them.

You only record. You don't need to edit, style or export anything.

## Before you start (2 minutes)

- Display at 1920 × 1080, or a Retina display at its default "looks like" size.
- Focus on, Do Not Disturb on, Dock auto-hide on, desktop clear.
- **Linear** is the demo app for every take: the desktop app, or linear.app in
  one browser window. Use a separate demo workspace (Settings › Workspaces ›
  Create workspace, e.g. "Fernhill") so no real issues or teammates show up.
  Give it one team ("Design") and about ten issues with plausible titles,
  for example "Redesign onboarding checklist" or "Fix export progress bar".
  Linear's light theme zooms best.
- Camera on, facing a window or a lamp. Mic on. A plain wall behind you is fine.
  Cutout and pop-out remove it anyway.
- In CaptureCat: 60 fps, cursor and keystroke capture on (both are defaults).

## The takes

Record each take as its own project and give it the name in **bold**. Move
slowly and deliberately, with a second's pause between actions. Pauses are
what make auto zoom look good.

### 1. **Site – Form** (60–90 s, camera + mic on, the main take)

In the Linear demo workspace, on the team's issue list:

1. Two seconds of stillness, cursor resting.
2. Press **C** (or click **New issue**). The New issue window opens.
3. Type a title, e.g. "Add a launch video to the homepage".
4. Click **Status** and pick **In Progress**.
5. Click **Priority** and pick **High**.
6. Click **Assignee** and pick yourself, then **Labels** and pick one.
7. Press **⌘↩** to create it. The issue appears in the list.
8. Scroll the list down a little, then back up. Rest for two seconds.

Say one short sentence per action, for example "First I name the issue…"
These become the captions.

*This one take becomes:* the homepage hero loop, auto zoom, cursor smoothing,
captions, the keystroke pill (C, ⌘↩), all four camera layouts (bubble, cutout,
pop-out card, split screen), aspect ratios, 3D tilt, and the before/after pair.
Claude exports it twice, once with every effect off and once with them on.

### 2. **Site – Private** (20 s, camera off)

In Linear: open **Settings › Account › Profile**, which shows your email, then
**Settings › API**. Create a personal API key called "Demo" so it's on screen,
hover near the key and click **Copy**. Revoke the key right after recording.
The raw take shows real data, but the exported clip blurs it, and that's the
feature being shown.

*Becomes:* the blur and spotlight clip.

### 3. **Site – Talk** (20 s, camera + mic on)

Look at the camera and say one or two natural sentences about CaptureCat. The
screen can stay on the Linear issue list.

*Becomes:* the split screen and camera-only shots.

### 4. **Site – iPhone** (optional, 15 s)

iPhone plugged in over USB. Record it toggling a switch in Settings.

*Becomes:* the iPhone and iPad bezel clip on the features page.

## Screenshots of the real app (5 minutes)

Take these with CaptureCat's own screenshot mode (window capture) and save
them anywhere. Tell Claude where they are. These show CaptureCat's own
windows, not Linear.

1. The recording panel open, with the display / window / area picker visible.
2. The editor with **Site – Form** open, in dark mode, playhead over a zoom block.
3. The same editor in light mode.
4. The export sheet with 4K selected and the size estimate showing.
5. The library with ⌘K search open on a word that appears inside a recording.
6. The web capture panel with `capturecat.so` entered.
7. The installer window: open the test DMG (`/tmp/CaptureCat-test.dmg`) and
   capture its window.

## For the share and agents pages (optional, later)

- Upload **Site – Form** as a share link from the app, then add two comments
  at different timestamps from another browser. Claude screenshots the share
  page and its analytics.
- With **Site – Form** open in the editor, record the screen while Claude edits
  the project through the CaptureCat MCP server in a terminal. That's the
  agents demo, and it's real.

## Then

Tell Claude the takes are done. It will:

1. Read each project through the CaptureCat MCP server and place auto zoom,
   captions, camera layout blocks, styles and blurs.
2. Check every clip frame by frame with the editor's own frame renders.
3. Export each clip from CaptureCat, compress it with ffmpeg (H.264, about
   4–6 Mbps, under 8 MB) into `apps/web/public/media/`, and make posters.
4. Replace every HTML recreation on the site with the real clip or screenshot,
   and delete the recreations so nothing fake can come back.
