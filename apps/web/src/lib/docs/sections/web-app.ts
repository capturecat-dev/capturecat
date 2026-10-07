import type { DocSection } from "../types";

/**
 * Checked against apps/web/src: components/dashboard/recorder.tsx,
 * recorder-bar.tsx, camera-bubble.tsx, app-sidebar.tsx, editor-projects.tsx,
 * editor/record/* (capture.ts, useRecorder.ts, session.ts, barHidden.ts,
 * publish.ts), editor/ui/EditorPage.tsx (WebGPUGate), editor/ui/export,
 * editor/ui/history, editor/transcribe/model.ts, lib/platforms.ts; Mac
 * CloudSyncController.swift, CloudProjectSync.swift, MergeReviewDialog.swift,
 * HistoryPaneAppKit.swift, EditorShellViewController.swift; API
 * routes/cloud-projects.ts, lib/upload-policy.ts and migrations 0008, 0027.
 */
const CHECKED = "2026-10-07";

export const WEB_APP: DocSection = {
  id: "web-app",
  title: "CaptureCat in the browser",
  description: "Record and edit in the browser, and move projects between Mac and web.",
  pages: [
    {
      slug: "web-app",
      title: "CaptureCat in the browser: record and edit on any computer",
      navTitle: "Overview",
      description:
        "Record your screen and edit in the browser on Windows, Linux, ChromeOS or a Mac. What the CaptureCat web app needs and how it differs from the Mac app.",
      summary:
        "The CaptureCat web app records a display, a window or a browser tab with your camera and microphone, then opens the take in a web editor that uses the same project format as the Mac app. It runs in current Chrome, Edge, Safari and Firefox, and keeps projects in your CaptureCat cloud storage.",
      platforms: ["web"],
      plan: "pro",
      blocks: [
        { type: "h2", text: "What you need" },
        {
          type: "list",
          items: [
            "**A CaptureCat account.** Sign in at [capturecat.so/app](https://capturecat.so/app).",
            "**A plan with cloud storage.** Web recordings and web editor projects are saved in your CaptureCat cloud storage, which comes with Pro. On the free plan you can still record, but the take cannot be saved to the cloud; it stays in your browser and you can download it.",
            "**A browser with WebGPU for the editor:** Chrome or Edge 113+, Safari 26+, or Firefox 141+. Other browsers see **This browser can’t run the editor**.",
            "**A computer.** Recording needs browser screen sharing, which phones and tablets do not offer.",
          ],
        },
        { type: "h2", text: "Mac app and web app compared" },
        {
          type: "table",
          head: ["", "Mac app", "Web app"],
          rows: [
            ["Runs on", "macOS 14 Sonoma or later", "Windows, Linux, ChromeOS or a Mac, in a supported browser"],
            ["Records", "A display, a window, a dragged area, an iPhone or iPad over USB, or a web page by URL", "A display, a window, or a browser tab"],
            ["Camera and microphone", "Yes, camera on its own track", "Yes, camera on its own track"],
            ["System audio", "Yes", "Tab audio in Chrome and Edge, whole-screen audio where the operating system shares it, none in Safari"],
            ["Frame rate", "60 fps", "Up to 60 fps in Chrome and Edge; Safari usually captures at 30"],
            ["Clicks, cursor path and keystrokes", "Recorded as data, so cursor smoothing, click zooms, auto zoom and the keystroke overlay work", "Not available; the browser draws the cursor into the video"],
            ["Editing", "The full editor", "The web editor, on the same project file"],
            ["Export", "MP4, MOV or GIF, up to 4K at 60 fps", "MP4, MOV or GIF, up to 4K at 60 fps"],
            ["Where projects live", "On your Mac. Free.", "In your CaptureCat cloud storage, with Pro"],
          ],
        },
        {
          type: "p",
          text: "Recordings made on the Mac keep their cursor, click and keystroke data when you open them in the web editor, so a common workflow is to record on the Mac and edit or hand off in the browser. See [Mac and web round trip](/docs/web-app/mac-and-web).",
        },
        { type: "h2", text: "Where things are" },
        {
          type: "table",
          head: ["Sidebar item", "What it is"],
          rows: [
            ["**Library**", "Your shared videos, with links, comments and analytics."],
            ["**Record**", "The browser recorder. See [Record in the browser](/docs/web-app/record)."],
            ["**Projects**", "Editable projects in your cloud, from web recordings or sent from the Mac. Open one to edit it. See [The web editor](/docs/web-app/editor)."],
          ],
        },
      ],
      faqs: [
        {
          question: "Can I use CaptureCat on Windows or Linux?",
          answer:
            "Yes, in the browser. The CaptureCat web app records and edits in current Chrome, Edge or Firefox on Windows, Linux and ChromeOS. The Mac app is only for macOS.",
        },
        {
          question: "Do I need to install anything to record in the browser?",
          answer: "No. Sign in at capturecat.so/app and open Record. The browser asks for permission to share your screen, camera and microphone.",
        },
        {
          question: "Why can't the browser record my clicks and keystrokes?",
          answer:
            "Browsers only share the screen's pixels, with the cursor already drawn in. The Mac app records clicks, the cursor path and keystrokes as separate data, which is what powers auto zoom, cursor smoothing and the keystroke overlay.",
        },
      ],
      related: ["web-app/record", "web-app/editor", "web-app/mac-and-web"],
      lastModified: CHECKED,
    },
    {
      slug: "web-app/record",
      title: "Record your screen in the browser with camera and mic",
      navTitle: "Record in the browser",
      description:
        "Record a display, window or browser tab with a camera bubble and microphone in Chrome, Edge, Safari or Firefox. No install; the take opens in the web editor.",
      summary:
        "Open **Record** in the web app, choose **Display**, **Window** or **Tab**, pick your microphone and camera, and press the red record key. When you stop, the recording uploads to your CaptureCat cloud and opens in the web editor.",
      platforms: ["web"],
      plan: "pro",
      blocks: [
        { type: "h2", text: "Make a recording" },
        {
          type: "steps",
          steps: [
            {
              title: "Open Record",
              text: "Sign in and click **Record** in the sidebar, or go to [capturecat.so/app/record](https://capturecat.so/app/record). Optionally type a name in the **Untitled Recording** field.",
            },
            {
              title: "Choose a source",
              text: "In the bar at the bottom, choose **Display**, **Window** or **Tab**, then click **Choose Display**, **Choose Window** or **Choose Tab**. Your browser's own sharing picker opens; pick the screen, window or tab there.",
            },
            {
              title: "Pick your microphone and camera",
              text: "Open the microphone and camera menu (the chip reads **Mic** or **No Mic** and **Cam** or **No Cam**). Under **Microphone** pick **System Default**, a device, or **No Microphone**. Under **Camera Overlay** pick a camera or **No Overlay**. If device names are missing, click **Allow Camera & Microphone…**.",
            },
            {
              title: "Choose system audio",
              text: "**Audio On** records the audio of the screen or tab you share; **Audio Off** records only your microphone. When sharing a tab in Chrome or Edge, tick the picker's option to also share tab audio.",
            },
            {
              title: "Record",
              text: "Press the red record key. After the countdown (3 seconds by default), recording starts and the bar hides itself so it stays out of your video.",
            },
            {
              title: "Stop",
              text: "Come back to the tab and click **Stop**, press **⌘⇧S** (**Ctrl+Shift+S** on Windows and Linux), press **Escape**, or use the browser's own stop-sharing button.",
            },
            {
              title: "Edit",
              text: "The recording uploads, showing its progress, and then opens in the web editor as a new project.",
            },
          ],
        },
        { type: "h2", text: "The recording bar" },
        {
          type: "p",
          text: "The bar sits at the bottom of every page in the web app, so you can start a take from anywhere and keep browsing your library while it records. During a take it shows the timer and these keys:",
        },
        {
          type: "table",
          head: ["Control", "What it does"],
          rows: [
            ["**Pause** / **Resume**", "Pauses the take; the timer shows **Paused**."],
            ["**Restart**", "Throws the take away and starts again, after you confirm."],
            ["**Stop**", "Ends the take and saves it."],
            ["**Delete**", "Throws the take away, after you confirm."],
          ],
        },
        {
          type: "p",
          text: "Before recording, the gear menu has **Recording Countdown** (Off, 3s, 5s or 10s), **Duration Limit** (No Limit, or 15 seconds up to 10 minutes; the take stops on its own when it is reached) and **Floating controls**. Your choices are remembered in this browser. The **×** key releases the camera, microphone and source.",
        },
        { type: "h3", text: "Keeping the bar out of your video" },
        {
          type: "list",
          items: [
            "**Sharing another tab:** nothing needs to hide, because the bar is not in that tab.",
            "**Sharing a window with Floating controls on:** the controls move to a small always-on-top window, outside what you record.",
            "**Sharing a display, this tab, or a window without floating controls:** the bar fades out before the first frame. Return to the tab, or rest the pointer at the very bottom of the page, to bring it back.",
            "Any moment the bar was on screen is cut from the new project automatically. The original recording keeps every frame, so you can remove the cut in the editor to get those moments back.",
          ],
        },
        { type: "h2", text: "The camera bubble" },
        {
          type: "list",
          items: [
            "When a camera is selected, a mirrored squircle bubble shows your camera on the page. Drag it anywhere; right-click it for **Small**, **Medium** or **Large**. Its size and position are remembered.",
            "Your camera is recorded as its own track, not burned into the screen video. In the editor you can restyle, move or hide it like a camera recorded on the Mac. See [Camera](/docs/recording/camera).",
            "When the bubble would appear in your own recording (a display share, or a share of this tab), it hides during the take; your camera is still recorded.",
          ],
        },
        { type: "h2", text: "Browser support" },
        {
          type: "table",
          head: ["Browser", "Recording", "System audio"],
          rows: [
            ["Chrome, Edge", "Up to 60 fps", "Tab audio; whole-screen audio where the operating system shares it"],
            ["Firefox", "Supported where the browser offers screen sharing and video encoding", "Where the operating system shares it"],
            ["Safari", "Usually 30 fps", "None. The button reads **No System Audio** and only your microphone is recorded"],
          ],
        },
        {
          type: "p",
          text: "A browser that cannot share the screen or encode video shows **This browser can't record**. Recording is captured at up to 4K; the badge on the stage shows the size and frame rate your browser actually delivers.",
        },
        { type: "h2", text: "Uploading and plans" },
        {
          type: "p",
          text: "When you stop, the take is saved in your browser first and then uploaded to your CaptureCat cloud storage as an editable project. If you try to leave the page while it uploads, CaptureCat warns you; if you leave anyway, the recording stays in this browser.",
        },
        {
          type: "list",
          items: [
            "If an upload fails, choose **Try again**, **Download** (saves `recording.mov`) or **Record Another**.",
            "Takes that never finished uploading are listed on the Record page under **Not uploaded yet**, with **Download**, **Delete** and **Upload**.",
            "Projects need a plan with cloud storage. On a plan without it, the upload is refused with a message saying so, and the take stays in your browser for download.",
          ],
        },
        {
          type: "callout",
          tone: "note",
          title: "Projects use CaptureCat storage",
          text: "Web projects are always kept in CaptureCat cloud storage and count toward your plan's storage, even if you connected your own bucket. Share videos you publish from the web editor do go to your bucket. See [Custom storage](/docs/custom-storage).",
        },
      ],
      faqs: [
        {
          question: "How do I record my screen in the browser?",
          answer:
            "Sign in to CaptureCat, open Record, choose Display, Window or Tab, pick your mic and camera, and press the red record key. When you stop, the recording opens in the web editor.",
        },
        {
          question: "Can I record system audio in the browser?",
          answer:
            "In Chrome and Edge you can record a tab's audio, and whole-screen audio where your operating system shares it. Safari cannot record system audio; your microphone is still recorded.",
        },
        {
          question: "Will the recording bar show up in my video?",
          answer:
            "No. The bar hides before the first frame, or moves to a floating window, and any moment it does appear is cut from the project automatically.",
        },
        {
          question: "Does the web recorder have a time limit?",
          answer:
            "Only the Duration Limit you choose in the recorder's settings. Your plan's storage still has to fit the recording.",
        },
      ],
      related: ["web-app/editor", "web-app", "recording/camera"],
      lastModified: CHECKED,
    },
    {
      slug: "web-app/editor",
      title: "Edit screen recordings in the browser",
      navTitle: "Web editor",
      description:
        "CaptureCat's web editor brings backgrounds, zooms, captions, blur, annotations and export to the browser, on the same project file as the Mac app.",
      summary:
        "The web editor opens any project in your CaptureCat cloud, whether you recorded it in the browser or sent it from the Mac. It renders the preview and the export with the same WebGPU engine, so the file you download matches what you saw.",
      platforms: ["web"],
      plan: "pro",
      blocks: [
        { type: "h2", text: "Open a project" },
        {
          type: "list",
          items: [
            "Click **Projects** in the web app sidebar and open a project.",
            "A new browser recording opens in the editor as soon as it has uploaded.",
            "On the Mac, choose **Open in Web Editor** on a capture to send it to the cloud and open it here. See [Mac and web round trip](/docs/web-app/mac-and-web).",
          ],
        },
        {
          type: "p",
          text: "The editor needs WebGPU: Chrome or Edge 113+, Safari 26+, or Firefox 141+. Changes save to your cloud automatically a moment after each edit; the pill in the top bar shows **Saved**, **Saving…** or **Offline**, and saving resumes when you are back online. **Captures** (Command-O) returns to your projects.",
        },
        { type: "h2", text: "What you can edit" },
        {
          type: "p",
          text: "The web editor reads and writes the same project format as the Mac editor, with inspector tabs for **Background**, **Cursor**, **Camera**, **Audio**, **Effects**, **Motion**, **Subtitles**, **Brand** and **Annotate**, and a timeline with video, voice, effects, focus and annotation lanes. Pick an aspect ratio (Auto, 16:9, 4:3, 1:1, 9:16, 21:9 or 4:5) in the top bar. The [Editing](/docs/editing) guides describe each feature.",
        },
        {
          type: "list",
          items: [
            "**Cursor, click and keystroke features** need a recording made on the Mac, which captures that data. Browser recordings have the cursor drawn into the video.",
            "**Captions** are transcribed in your browser with the same English Whisper model the Mac app uses: click **Generate Subtitles** in the **Subtitles** tab. The model downloads once (about 210 MB); your audio is not sent to a server.",
            "**Auto Zoom** (in the timeline's Zoom menu) needs recorded cursor data, so it is available for Mac recordings only.",
            "**Voice-over:** click **Record Voice Over** in the timeline toolbar to narrate onto the voice lane.",
            "**Agents** can edit the open project through WebMCP in browsers that support it. See [WebMCP in the web editor](/docs/ai-agents/tools#webmcp-in-the-web-editor).",
          ],
        },
        { type: "h2", text: "Export and share" },
        {
          type: "p",
          text: "Click **Export…** to export MP4, MOV or GIF at 720p, 1080p, 4K or a custom size, at 30 or 60 fps (GIFs are capped at 20 fps and 960 pixels). The file saves to your computer. **Share** uploads the video and gives you a share link, the same as sharing from the Mac. See [Export](/docs/export-and-sharing/export) and [Share links](/docs/export-and-sharing/share-links).",
        },
        { type: "h2", text: "Keyboard shortcuts" },
        {
          type: "shortcuts",
          rows: [
            ["Space", "Play or pause"],
            ["← / →", "Step one frame"],
            ["⇧← / ⇧→", "Step one second"],
            ["⌘B", "Split at the playhead"],
            ["B", "Slice tool"],
            ["⌘D", "Duplicate the selection"],
            ["⌫", "Delete the selection"],
            ["⌘Z / ⇧⌘Z", "Undo / redo"],
            ["⌥⌘I", "Show or hide the inspector"],
            ["⌘O", "Back to projects"],
          ],
        },
        {
          type: "p",
          text: "On Windows and Linux, use Ctrl in place of ⌘.",
        },
        { type: "h2", text: "History" },
        {
          type: "p",
          text: "Click the History key (the clock) in the top bar to see earlier versions of the project from the web and the Mac. From a version's menu you can preview it, **Name This Version…**, compare it with the current one, or **Restore** it. See [Project history](/docs/web-app/mac-and-web#project-history).",
        },
      ],
      faqs: [
        {
          question: "Can I edit a Mac recording in the browser?",
          answer:
            "Yes. In the Mac app, right-click the capture and choose Open in Web Editor. It uploads to your CaptureCat cloud and opens in the browser with its cursor, click and keystroke data intact.",
        },
        {
          question: "Why does the web editor say this browser can't run the editor?",
          answer:
            "The editor renders with WebGPU. Use Chrome or Edge 113 or later, Safari 26 or later, or Firefox 141 or later, with hardware acceleration turned on.",
        },
      ],
      related: ["web-app/mac-and-web", "web-app/record", "editing"],
      lastModified: CHECKED,
    },
    {
      slug: "web-app/mac-and-web",
      title: "Move projects between the Mac app and the web editor",
      navTitle: "Mac and web round trip",
      description:
        "Open a Mac recording in CaptureCat's web editor, pull the web edits back to your Mac, merge changes made in both places, and restore earlier versions.",
      summary:
        "**Open in Web Editor** uploads a Mac project to your CaptureCat cloud and opens it in the browser. **Pull Web Edits** brings changes made there back to the Mac. When both sides changed, CaptureCat merges them and asks you only about real conflicts.",
      platforms: ["mac", "web"],
      plan: "pro",
      blocks: [
        { type: "h2", text: "Send a project to the web editor" },
        {
          type: "steps",
          steps: [
            {
              title: "Choose Open in Web Editor",
              text: "In the Mac editor, click **Web Editor** in the top bar and choose **Open in Web Editor**. In the library, right-click a capture and choose **Open in Web Editor**.",
            },
            {
              title: "Sign in if asked",
              text: "The web editor keeps the project in your CaptureCat account, so you need to be signed in.",
            },
            {
              title: "Wait for the upload",
              text: "A progress dialog shows the upload; **Cancel** stops it. Only files the cloud does not already have are uploaded, so later syncs are quick.",
            },
            {
              title: "Edit in the browser",
              text: "Your browser opens the project in the web editor at `app.capturecat.so/editor`. Cursor, click and keystroke data come with it.",
            },
          ],
        },
        { type: "h2", text: "Bring web edits back to the Mac" },
        {
          type: "p",
          text: "Choose **Pull Web Edits** from the same **Web Editor** menu or the capture's right-click menu. CaptureCat downloads the latest version and any files your Mac is missing, such as a voice-over recorded in the browser. If the Mac already has the latest version, it says **Already up to date**. If the project was never opened on the web, it offers **Open in Web Editor** instead.",
        },
        { type: "h2", text: "When both sides changed" },
        {
          type: "list",
          items: [
            "**Changes that do not clash are merged automatically**, for example a zoom added on the Mac and a caption fixed on the web. A notice says what was merged.",
            "**Small clashes** on the same setting go to the most recent edit, and both versions are kept in History.",
            "**Real conflicts** open a review dialog (for example **Review 2 conflicts**): for each one, choose **Mine** or **Theirs**, then **Apply Merge**.",
            "If the two versions cannot be merged, CaptureCat asks: **Pull Web Edits** replaces this Mac's unsynced changes with the web version, and **Replace Web Version** overwrites the web version with the Mac's.",
          ],
        },
        { type: "h2", text: "Project history", id: "project-history" },
        {
          type: "p",
          text: "Once a project is in the cloud, every sync, web edit and merge is kept as a version. Open it with the clock key in the Mac editor's top bar, or **Web Editor → History…**, and with the History key in the web editor.",
        },
        {
          type: "list",
          items: [
            "**Preview** shows an earlier version in the editor without changing anything; **Restore This Version…** (Mac) or **Restore** (web) makes it current again.",
            "**Name This Version…** keeps a version past the retention window.",
            "**Compare with Current** lists what changed.",
            "On the Mac, **Sync now** uploads the project without opening the browser.",
            "Versions keep the media they used, which counts toward your storage. **Free up** deletes the unnamed versions holding media the project no longer uses.",
          ],
        },
        {
          type: "table",
          head: ["Plan", "Unnamed versions kept", "Named versions per project"],
          rows: [
            ["Free", "No history", "None"],
            ["Pro", "30 days", "25"],
            ["Business", "365 days", "500"],
          ],
        },
        {
          type: "callout",
          tone: "pro",
          text: "Sending projects to the web editor needs a plan with CaptureCat cloud storage. On the free plan, Open in Web Editor explains that your plan does not include it. Projects count toward your plan's storage.",
        },
      ],
      faqs: [
        {
          question: "Can I start a recording on my Mac and finish editing in the browser?",
          answer:
            "Yes. Choose Open in Web Editor on the capture, edit in the browser, then choose Pull Web Edits on the Mac to bring the changes back.",
        },
        {
          question: "What happens if I edit the same project on the Mac and the web?",
          answer:
            "CaptureCat merges the changes. Edits that do not clash are combined automatically, and for real conflicts you choose which side to keep. Both versions stay in History.",
        },
        {
          question: "Can I get back an earlier version of a project?",
          answer:
            "Yes, on Pro and Business. Open History in the Mac or web editor, preview the version, and restore it. Name a version to keep it beyond the retention window.",
        },
      ],
      related: ["web-app/editor", "web-app", "library"],
      lastModified: CHECKED,
    },
  ],
};
