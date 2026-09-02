# Marketing site media guide

The marketing pages have 27 slots for screenshots and screen recordings of the
app. Each one renders as a dashed glass placeholder with its instructions
written inside it until you supply the file. Walk the site at
http://localhost:3200 and every empty slot tells you what it wants.

## How to fill a slot

1. Record or screenshot the thing described below.
2. Save it as `apps/web/public/media/<id>.mp4` (video) or `<id>.png`
   (screenshot). Any name works, but matching the id keeps things findable.
3. Open `apps/web/src/lib/media-shots.ts`, find the entry with that id, and
   add `src: "/media/<id>.mp4"`. For videos, add `poster: "/media/<id>.jpg"`
   if you have a still, so the page paints before the video loads.
4. Reload. The placeholder becomes the real media in the same frame.

The placeholder is gone as soon as `src` is set, so the site can go live with
some slots filled and some not.

## Recording rules that apply to every clip

- Record in CaptureCat and export from CaptureCat. The site is selling the
  export, so the clips are the export.
- 1080p minimum, 60 fps for anything with cursor motion or zooms, 30 fps is
  fine for screenshots and static screens.
- 8 to 25 seconds. Clips loop, so where possible end on the frame you started
  on, or end on a still frame that holds for a second.
- No audio plays on the site. Captions are the only thing viewers can read,
  so narrate anything you want them to see written down.
- Use one wallpaper, one cursor style, and one app across the whole set so
  the pages feel like one product. A calm gradient or a macOS wallpaper both
  work. Avoid the pink to purple demo gradient, it reads as a placeholder.
- Pick a demo app people recognise and that looks good zoomed in. A settings
  screen, a form, a dashboard. Avoid terminals except where the guide asks
  for one.
- Hide your own personal data. Blur it in CaptureCat if it has to be on
  screen, which is also a feature demo.
- Compress with HandBrake or ffmpeg to H.264, around 4 to 6 Mbps for 1080p.
  Keep each file under 8 MB where you can. Example:

```bash
ffmpeg -i in.mp4 -c:v libx264 -crf 24 -preset slow -an -movflags +faststart out.mp4
```

## Home page

| id | Kind | Aspect | What to make |
| --- | --- | --- | --- |
| `hero-loop` | video | 16:9 | Your single best export. 20 seconds, wallpaper background, two or three auto zooms on clicks, smoothed cursor, one caption line. This is the first thing every visitor sees. |
| `before-raw` | video | 16:9 | A 12 second task recorded with QuickTime, or with every CaptureCat effect switched off. Full screen, no zoom, small jittery cursor, no background. |
| `before-capturecat` | video | 16:9 | The exact same 12 seconds exported from CaptureCat with auto zoom, cursor smoothing, click ripples, and a wallpaper. Start both clips on the same frame so they play in sync side by side. Record it once in CaptureCat and export twice: once with all effects off, once with them on. |
| `step-record` | image | 4:3 | The recording panel with the source picker open: display, window, area, plus camera and mic toggles. |
| `step-auto-edit` | video | 4:3 | Stop a recording and let the editor open. Capture the moment the timeline fills with zoom blocks on its own. 8 seconds. |
| `step-style` | video | 4:3 | In the inspector: change the wallpaper, then the padding, then switch on a squircle frame or the iPhone bezel. Slow, deliberate clicks so each change is readable. |
| `step-share` | image | 4:3 | The moment an upload finishes and the share link is shown with the copy button. |
| `feature-auto-zoom` | video | 16:9 | Click into three different fields one after another, a second apart. Export with Auto Zoom on and the Cinematic animation style. |
| `feature-cursor` | video | 16:9 | Move the cursor across the screen in a rough hand drawn path, click twice. Export with smoothing on, a bigger cursor, and click ripples so the difference is obvious. |
| `feature-captions` | video | 16:9 | Narrate a click for 10 seconds. Export with captions on and the karaoke word highlight preset. The words lighting up in time is the point. |
| `feature-framing` | video | 16:9 | Cycle the same recording through a gradient, a macOS wallpaper, a solid colour, and transparent, then switch the aspect ratio to 9:16. Hold each state for two seconds. |
| `feature-camera` | video | 16:9 | A recording with the webcam bubble on. Move it to another corner, switch circle to squircle, show the name tag pill. |
| `feature-focus` | video | 16:9 | A screen with an email address or API key visible. Drag a blur region over it on the preview, then add a spotlight that dims everything except one button. |
| `feature-timeline` | video | 16:9 | The timeline with all five lanes visible. Split a clip with Command B, drag a zoom block wider, add a speed region. Keep the whole editor window in frame. |
| `share-page` | image | 16:10 | A capturecat.so share page in Safari with two or three timestamped comments under the player. Use a real recording. |
| `share-analytics` | image | 16:10 | The analytics tab for a video with real views. The retention curve and the click row are what people look at. |

## Features page

| id | Kind | Aspect | What to make |
| --- | --- | --- | --- |
| `features-iphone` | video | 16:9 | Record an iPhone over USB doing something simple, like toggling a switch in Settings. Export with the photoreal bezel on a wallpaper. |
| `features-web-capture` | image | 16:10 | The web capture panel with a URL entered, the viewport picker showing desktop, tablet, and mobile, and the full page and dark mode toggles. |
| `features-annotations` | video | 16:9 | Add an arrow pointing at a button, a text callout, and a looping tap indicator. Play it back so the build in animations show. |
| `features-keystrokes` | video | 16:9 | With the keystroke overlay on, press Command K, type a few characters, then Command Enter. The pill should show each shortcut as it happens. |
| `features-library-search` | image | 16:10 | The project browser with Command K search open and a query that matches text inside a recording, with the result showing the matched frame. |
| `features-export` | image | 3:2 | The export sheet with 4K selected, the quality preset picker, and the live bitrate and file size estimate visible. |

## Agents page

| id | Kind | Aspect | What to make |
| --- | --- | --- | --- |
| `agents-session` | video | 16:9 | Split view: Claude Code in a terminal on the left, CaptureCat on the right. Type a request to add zooms where you clicked and export. Let the tool calls print and the zoom blocks appear in the app. 25 seconds. This is the one clip where a terminal is welcome. |
| `agents-connect-menu` | image | 3:2 | The CaptureCat menu bar menu open with Connect AI Agents visible, and the client picker window if it opens. |

## Download page

| id | Kind | Aspect | What to make |
| --- | --- | --- | --- |
| `download-first-launch` | image | 3:2 | First launch: the macOS Screen Recording permission prompt, or CaptureCat's own permissions step, whichever appears first. |
| `download-menu-bar` | image | 3:2 | The CaptureCat menu bar icon with its menu open, cropped tight to the top right of the screen. |

## Pricing page

| id | Kind | Aspect | What to make |
| --- | --- | --- | --- |
| `pricing-dashboard` | image | 16:10 | The web dashboard at capturecat.so/app with a handful of shared videos and view counts visible. |

## Suggested order

If you only do a few, do these first, in this order:

1. `hero-loop`
2. `before-raw` and `before-capturecat` (one recording, two exports)
3. `feature-auto-zoom`
4. `feature-cursor`
5. `share-page`

Those five cover the home page above the fold and the two sections that make
the argument for the product.
