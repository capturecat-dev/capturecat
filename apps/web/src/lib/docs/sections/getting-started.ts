import type { DocSection } from "../types";

/**
 * Checked against apps/macos/CaptureCat: OnboardingViewController (steps,
 * permission rows, button titles), Info.plist + CaptureCat.entitlements,
 * KeystrokeTracker / ScreenshotHotkeys (Input Monitoring, Accessibility),
 * ScreenRecorder (macOS 15 mic, 60 fps), CaptureCatAppDelegate (main menu,
 * Dock menu, status item), StatusMenuBuilder, SettingsWindowController,
 * EditorShellViewController (toolbar, PreviewZoomPill), InspectorTab and the
 * InspectorKit panes, TimelineViewController (lanes, toolbar, key handling),
 * ProjectBrowserViewController (delete key), ExportSheetController (export is
 * free and local); apps/api migrations 0008/0016/0023/0029 (plan features);
 * apps/web lib/platforms.ts and routes/download.tsx.
 */
const CHECKED = "2026-10-07";

export const GETTING_STARTED: DocSection = {
  id: "getting-started",
  title: "Getting started",
  description: "Install CaptureCat, grant permissions, and make your first recording.",
  pages: [
    {
      slug: "getting-started",
      title: "What is CaptureCat? A screen recorder for Mac and the web",
      navTitle: "Overview",
      description:
        "CaptureCat is a free, native Mac screen recorder whose editor zooms in on your clicks, plus a browser app. What each app does, and what Pro adds.",
      summary:
        "CaptureCat is a screen recorder and editor. The Mac app records your screen, camera and audio, then opens the take in an editor with zooms already placed on your clicks; recording, editing and exporting on the Mac are free, and Pro adds share links, web page capture and cloud projects.",
      platforms: ["mac", "web"],
      blocks: [
        { type: "h2", text: "The Mac app" },
        {
          type: "p",
          text: "CaptureCat for Mac is a native app that lives in your menu bar. It records a display, a single window, an area you drag out, a connected iPhone or iPad, or a web page by URL. It can also take screenshots of the same sources.",
        },
        {
          type: "p",
          text: "While you record, CaptureCat saves your clicks, cursor path and keystroke timing as data rather than burning them into the video. That is what lets the editor smooth the cursor, zoom in on clicks automatically, play typing sounds and show the shortcuts you pressed, all after the fact.",
        },
        {
          type: "list",
          items: [
            "**Record:** displays, windows, areas, iPhone and iPad over USB, and web pages. See [Recording](/docs/recording).",
            "**Edit:** auto zoom, cursor styling, backgrounds and frames, a camera bubble, annotations, captions, blur and a multi-lane timeline. See the [editor tour](/docs/getting-started/editor-tour).",
            "**Export:** save a video file at full quality with no watermark and no account. See [Export](/docs/export-and-sharing/export).",
            "**Share (Pro):** upload to a share link with comments and analytics. See [Share links](/docs/export-and-sharing/share-links).",
          ],
        },
        { type: "h2", text: "The web app" },
        {
          type: "p",
          text: "The web app runs in a browser on Windows, Linux, ChromeOS or a Mac. It records a display, a window or a browser tab, and edits projects in a web editor that opens the same project files as the Mac app. See [Web app](/docs/web-app).",
        },
        {
          type: "table",
          head: ["", "Mac app", "Web app"],
          rows: [
            ["Runs on", "macOS 14 Sonoma or later, Apple silicon and Intel", "Chrome or Edge 113+, Safari 26+, or Firefox 141+. The editor needs WebGPU."],
            ["Records", "A display, a window, an area, an iPhone or iPad, or a web page by URL", "A display, a window, or a browser tab"],
            ["Camera and microphone", "Yes, camera on its own track", "Yes, camera on its own track"],
            ["System audio", "Yes", "Tab audio in Chrome and Edge, whole-screen audio where the operating system shares it, none in Safari"],
            ["Clicks, cursor path and keystrokes", "Recorded as data", "Not available; the browser burns the cursor into the video"],
            ["Where projects live", "On your Mac", "In your CaptureCat cloud storage, which comes with Pro"],
          ],
        },
        {
          type: "p",
          text: "Recordings made on the Mac keep their cursor, click and keystroke data when you open them in the web editor. See [Mac and web together](/docs/web-app/mac-and-web).",
        },
        { type: "h2", text: "What's free and what Pro adds" },
        {
          type: "table",
          head: ["", "Free", "Pro"],
          rows: [
            ["Record, edit and export on your Mac", "Yes", "Yes"],
            ["Share links with viewer comments and analytics", "No", "Yes"],
            ["[Web page capture](/docs/recording/web-page-capture) by URL", "No", "Yes"],
            ["Cloud projects and the [web editor](/docs/web-app/editor)", "No", "Yes"],
            ["Share videos stored in [your own S3 bucket](/docs/custom-storage)", "No", "Yes"],
          ],
        },
        {
          type: "p",
          text: "You don't need an account to record, edit or export on the Mac. Sign in only when you want a cloud feature. Storage and upload limits come from your plan; see [Plans](/docs/account/plans).",
        },
        {
          type: "callout",
          tone: "note",
          title: "Open source",
          text: "CaptureCat is open source under the AGPL-3.0 license. You can [build the Mac app from source](/docs/self-hosting/build-from-source) or [self-host the server](/docs/self-hosting).",
        },
        { type: "h2", text: "Next steps" },
        {
          type: "list",
          ordered: true,
          items: [
            "[Install CaptureCat and grant permissions](/docs/getting-started/install).",
            "[Make your first recording](/docs/getting-started/first-recording).",
            "[Take the editor tour](/docs/getting-started/editor-tour).",
            "Learn the [keyboard shortcuts](/docs/getting-started/keyboard-shortcuts).",
          ],
        },
      ],
      faqs: [
        {
          question: "Is CaptureCat free?",
          answer:
            "Yes. The Mac app records, edits and exports at full quality for free, with no watermark and no account. Pro is for hosted features: share links, comments, analytics, web page capture and cloud projects.",
        },
        {
          question: "Does CaptureCat work on Windows or Linux?",
          answer:
            "The Mac app needs macOS 14 or later. On Windows, Linux or ChromeOS, use the CaptureCat web app in Chrome, Edge, Safari or Firefox; its editor needs WebGPU.",
        },
        {
          question: "Do I need an account to use CaptureCat?",
          answer:
            "No. Recording, editing and exporting on the Mac work without signing in. You need an account for share links, cloud projects and web page capture.",
        },
      ],
      related: ["getting-started/install", "getting-started/first-recording", "web-app", "account/plans"],
      lastModified: CHECKED,
    },
    {
      slug: "getting-started/install",
      title: "Install CaptureCat on your Mac and grant permissions",
      navTitle: "Install and permissions",
      description:
        "System requirements, download and first launch for CaptureCat on Mac, and every macOS permission it asks for: Screen Recording, Microphone, Camera and more.",
      summary:
        "Download the build for your Mac, drag CaptureCat to Applications and open it. A short setup asks for Screen Recording, which is required, plus optional Notifications, Microphone and Camera access; other permissions are asked only when you turn on the feature that needs them.",
      platforms: ["mac"],
      blocks: [
        { type: "h2", text: "System requirements" },
        {
          type: "list",
          items: [
            "macOS 14 Sonoma or later.",
            "An Apple silicon or Intel Mac. There is a separate download for each.",
            "Recording your microphone along with the screen needs macOS 15 Sequoia or later. See [Audio](/docs/recording/audio).",
            "A USB cable to record an iPhone or iPad.",
          ],
        },
        { type: "h2", text: "Download and install" },
        {
          type: "steps",
          steps: [
            {
              title: "Download the app",
              text: "Go to [capturecat.so/download](https://capturecat.so/download) and pick the build for your Mac. To check which you have, open the Apple menu, choose **About This Mac** and look at **Chip**: Apple M1 or later is Apple silicon.",
            },
            {
              title: "Move it to Applications",
              text: "Open the downloaded disk image and drag CaptureCat into the Applications folder.",
            },
            {
              title: "Open CaptureCat",
              text: "Open it from Applications. The setup window walks you through permissions, sign-in and the screenshot tool choice.",
            },
          ],
        },
        { type: "h2", text: "First launch setup" },
        {
          type: "table",
          head: ["Step", "What you do"],
          rows: [
            ["Welcome", "Click **Get Started**."],
            ["Permissions", "Click **Grant** next to each permission you want. **Screen Recording** must be allowed before **Continue** is enabled."],
            ["Account", "Click **Sign In with Browser** to sign in, or **Skip for Now**. You can sign in later from the menu bar or **Settings → Account**."],
            ["Screenshots", "Choose **Yes, use CaptureCat for screenshots** or **No, keep my current screenshot tool**. See [Screenshots](/docs/recording/screenshots)."],
            ["Ready", "Tick **I agree to the Terms and Privacy Policy**, then click **Start Recording** to open the recording bar."],
          ],
        },
        { type: "h2", text: "Permissions CaptureCat asks for" },
        {
          type: "table",
          head: ["Permission", "What it's for", "When it's asked"],
          rows: [
            ["**Screen Recording**", "Required. Capturing displays, windows, areas and screenshots.", "Setup, Permissions step"],
            ["**Notifications**", "Optional. Reminders you set on captures.", "Setup, Permissions step"],
            ["**Microphone**", "Optional. Recording your voice with the screen, and recording a voice-over in the editor.", "Setup, Permissions step"],
            ["**Camera**", "Optional. The [camera bubble](/docs/recording/camera), and [recording an iPhone or iPad](/docs/recording/iphone-and-ipad), which macOS treats as a video device.", "Setup, Permissions step, or your first iPhone recording"],
            ["**Accessibility**", "Only for the **Default screenshot tool** setting, which lets CaptureCat take over ⇧⌘3, ⇧⌘4 and ⇧⌘5.", "When you turn that setting on"],
            ["**Input Monitoring**", "Keystroke timing for keyboard sounds and auto zoom, and the shortcut overlay. See [Keystrokes](/docs/recording/keystrokes).", "When you turn on **Capture Shortcuts** or click **Request Permission** in the editor's Cursor pane"],
            ["**Automation** (Terminal)", "Running the one-line setup command when you connect an AI agent.", "When you [connect an agent](/docs/ai-agents/setup)"],
          ],
        },
        {
          type: "p",
          text: "Each row in setup shows **Pending**, **Allowed** or **Blocked**. If a permission is blocked, its button changes to **Settings** and opens the matching page of **System Settings → Privacy & Security**, because macOS shows its own prompt only once.",
        },
        { type: "h3", text: "Screen Recording needs a relaunch" },
        {
          type: "p",
          text: "macOS applies a Screen Recording grant the next time an app launches. If you allow it while CaptureCat is open, click **Relaunch to Apply**.",
        },
        {
          type: "p",
          text: "If you denied it, open **System Settings → Privacy & Security → Screen Recording**, turn CaptureCat on, and relaunch. If CaptureCat is missing from the list, click **+** and add it from Applications.",
        },
        { type: "h2", text: "After setup" },
        {
          type: "list",
          items: [
            "CaptureCat puts a cat icon in the menu bar. Click it for **New Recording...**, **Browse Captures...**, **Settings…**, sign-in and **Check for Updates...**.",
            "The recording bar opens by itself once each time the app launches.",
            "If the menu bar is crowded and the icon is hidden, right-click CaptureCat in the Dock for **Browse Captures…** and **New Recording…**.",
          ],
        },
        { type: "h2", text: "Updates" },
        {
          type: "p",
          text: "CaptureCat checks for updates automatically. To check now, choose **Check for Updates...** from the menu bar icon, or click **Check Now** next to **Software updates** in **Settings → Account**. Turn on **Beta updates** there to get pre-release builds.",
        },
      ],
      faqs: [
        {
          question: "Why does CaptureCat need Screen Recording permission?",
          answer:
            "macOS only lets apps capture the screen with Screen Recording permission. CaptureCat needs it for every screen recording and screenshot; it is the one required permission.",
        },
        {
          question: "I allowed Screen Recording but CaptureCat still can't record. What do I do?",
          answer:
            "Quit CaptureCat completely and open it again, or click Relaunch to Apply in setup. macOS applies the permission only when the app launches.",
        },
        {
          question: "Does CaptureCat run on macOS Ventura?",
          answer: "No. CaptureCat for Mac needs macOS 14 Sonoma or later. On older Macs you can use the web app in a supported browser.",
        },
      ],
      related: ["getting-started/first-recording", "recording/audio", "recording/keystrokes", "getting-started"],
      lastModified: CHECKED,
    },
    {
      slug: "getting-started/first-recording",
      title: "Make your first screen recording on Mac",
      navTitle: "Your first recording",
      description:
        "Record your Mac screen with CaptureCat: open the recording bar, pick a display, add your mic, record, stop, and export the auto-zoomed result.",
      summary:
        "Click the CaptureCat icon in the menu bar, choose **New Recording...**, pick a source and press the red record button. When you stop, the editor opens with zooms already placed on your clicks, ready to export.",
      platforms: ["mac"],
      blocks: [
        {
          type: "steps",
          steps: [
            {
              title: "Open the recording bar",
              text: "Click the CaptureCat icon in the menu bar and choose **New Recording...**. While CaptureCat is the active app you can also press ⇧⌘N.",
            },
            {
              title: "Choose what to record",
              text: "Make sure **Record** is selected on the left of the bar, then pick a source tab. For a full screen, choose **Display** and pick a screen from **Choose Display**. **Window**, **Area**, **iPhone** and **URL** are covered in [Recording](/docs/recording).",
            },
            {
              title: "Set up your mic and camera",
              text: "Click the **Mic · No Cam** chip. Pick a microphone under **Microphone** and, if you want a webcam bubble, a camera under **Camera / iPhone Overlay**. The **Audio On** chip records the sound your Mac plays; click it to switch to **Audio Off**.",
            },
            {
              title: "Start recording",
              text: "Click the red record button. A 3 second countdown appears on the screen you're recording, then recording starts. The recording bar, the countdown and the camera preview never appear in the video.",
            },
            {
              title: "Record your demo",
              text: "Work as normal. The bar shows the recorded time, and has buttons to pause, switch source, restart, stop and delete. See [While you record](/docs/recording#while-you-record).",
            },
            {
              title: "Stop",
              text: "Click the red stop button in the bar, or choose **Stop Recording** from the menu bar icon. The editor opens. With **Auto zoom new recordings** on (the default), zooms are already placed on your clicks.",
            },
            {
              title: "Export",
              text: "Click **Export…** in the editor's top bar, choose your settings and save the file. Exporting is free and needs no account. To get a link instead, see [Share links](/docs/export-and-sharing/share-links).",
            },
          ],
        },
        { type: "h2", text: "Before you record" },
        {
          type: "list",
          items: [
            "**Countdown:** change or turn it off from the gear menu in the recording bar, under **Recording Countdown** (Off, 3s, 5s or 10s).",
            "**Time limit:** set **Duration Limit** in the same menu to stop automatically after a set recorded length.",
            "**Shortcut overlay:** turn on **Capture Shortcuts (⌘⇧S overlay)** in the gear menu if you want the shortcuts you press to appear in the video. See [Keystrokes](/docs/recording/keystrokes).",
            "**Microphone on macOS 14:** recording the mic with the screen needs macOS 15 or later. On macOS 14, add narration afterwards with a voice-over. See [Audio](/docs/recording/audio).",
          ],
        },
        { type: "h2", text: "Find your recordings" },
        {
          type: "p",
          text: "Every recording is saved as a project in your CaptureCat library. Click **Captures** in the editor's top bar, or choose **Browse Captures...** from the menu bar icon (⌘O while CaptureCat is active). See [Library](/docs/library).",
        },
        {
          type: "callout",
          tone: "tip",
          text: "Auto zoom works from the clicks CaptureCat records, so click on the things you want viewers to look at. You can turn it off in **Settings → General → Auto zoom new recordings**, or adjust zooms later. See [Auto zoom](/docs/editing/auto-zoom).",
        },
      ],
      faqs: [
        {
          question: "How do I stop a screen recording in CaptureCat?",
          answer:
            "Click the red stop button in the recording bar, or click the CaptureCat icon in the menu bar and choose Stop Recording. The editor opens with the recording.",
        },
        {
          question: "Will the recording bar show up in my video?",
          answer:
            "No. CaptureCat leaves its own windows out of every recording, including the recording bar, the countdown and the live camera preview.",
        },
      ],
      related: ["recording", "getting-started/editor-tour", "editing/auto-zoom", "export-and-sharing/export"],
      lastModified: CHECKED,
    },
    {
      slug: "getting-started/editor-tour",
      title: "CaptureCat editor tour: preview, inspector and timeline",
      navTitle: "Editor tour",
      description:
        "A tour of the CaptureCat Mac editor: the top bar, the live preview, the nine inspector panes, and the video, voice, effects, focus and annotate timeline lanes.",
      summary:
        "The editor has four areas: a top bar for the aspect ratio and export, a live preview you can drag things on, an inspector on the right with nine panes of settings, and a timeline with five lanes along the bottom.",
      platforms: ["mac"],
      blocks: [
        { type: "h2", text: "Top bar" },
        {
          type: "table",
          head: ["Control", "What it does"],
          rows: [
            ["**Captures**", "Back to your library of recordings, screenshots and notes."],
            ["Project title", "The project's name."],
            ["Aspect", "The output shape: **Auto** (match the recording), **16:9**, **4:3**, **1:1**, **9:16**, **21:9** or **4:5**. See [Framing](/docs/editing/framing)."],
            ["**Image** / **Video**", "Shown for screenshots and web page captures: keep the capture as a still image, or turn it into a short video."],
            ["History (clock icon)", "Opens the project's History pane in place of the inspector."],
            ["**Web Editor**", "Open this project in the [web editor](/docs/web-app/editor), or pull edits made there."],
            ["**Export…**", "Export a file or share a link. See [Export](/docs/export-and-sharing/export)."],
            ["Inspector button", "Show or hide the inspector (⌥⌘I)."],
          ],
        },
        { type: "h2", text: "Preview" },
        {
          type: "p",
          text: "The preview shows the frame at the playhead exactly as it will export. You can work on it directly: drag the camera bubble, your brand logo, captions and annotations; move and resize blur and highlight regions; aim a zoom's focal point; and drag the screen card to place it.",
        },
        {
          type: "p",
          text: "Zoom the preview with the **-** and **+** buttons below it (⌘- and ⌘=). Click the percentage to reset to 100%.",
        },
        { type: "h2", text: "Inspector" },
        {
          type: "p",
          text: "The inspector on the right has a rail of nine panes. Click an icon in the rail to switch panes.",
        },
        {
          type: "table",
          head: ["Pane", "Sections"],
          rows: [
            ["**Background**", "Background, Look, Frame (including **iPhone / iPad Frame**), Menu Bar. See [Framing](/docs/editing/framing)."],
            ["**Cursor**", "Cursor, Motion, Behavior, Click Effect, Keyboard Sounds, Shortcut Overlay. See [Cursor](/docs/editing/cursor)."],
            ["**Camera**", "Camera Overlay, Adjust, Style, Name Tag. See [Camera](/docs/recording/camera)."],
            ["**Audio**", "Volume for System Audio, Microphone and Voice Over. See [Editing audio](/docs/editing/audio)."],
            ["**Effects**", "Slide, Curtain Unveil, Parallax, Motion Blur."],
            ["**Motion**", "Zoom, Tilt, Highlight Mask, Depth Focus, Blur. See [Auto zoom](/docs/editing/auto-zoom) and [Privacy](/docs/editing/privacy)."],
            ["**Subtitles**", "Subtitles, Presets, Text, Style, Edit Subtitles. See [Captions](/docs/editing/captions)."],
            ["**Brand**", "Your logo, burned into the video, and its position."],
            ["**Annotate**", "Properties of the selected text label, arrow, shape or tap indicator. See [Annotations](/docs/editing/annotations)."],
          ],
        },
        { type: "h2", text: "Timeline" },
        {
          type: "p",
          text: "The timeline runs along the bottom with five lanes:",
        },
        {
          type: "table",
          head: ["Lane", "Holds"],
          rows: [
            ["**VIDEO**", "Your recording. Trim the ends, split it, and add speed regions."],
            ["**VOICE**", "Voice-over clips you record in the editor."],
            ["**EFFECTS**", "Zoom and tilt blocks, plus the Slide and Curtain Unveil openers."],
            ["**FOCUS**", "Blur, pixelate, highlight and depth focus regions, and camera layout spans."],
            ["**ANNOTATE**", "Text, arrows, callouts, drawings, shapes and tap indicators."],
          ],
        },
        {
          type: "p",
          text: "The toolbar above the lanes has, from left to right: **Go to Start**, play and **Go to End**; the timecode; **Undo**, **Redo** and **Delete Selected**; the **Zoom** menu (Auto Zoom, Zoom In, Showcase, Scale Down, Tilt, Slide, Curtain Unveil and the camera layouts); the **Focus & Blur** menu (Add Blur, Add Pixelate, Add Highlight, Add Depth Focus); the slice tool; **Split at Playhead (⌘B)**; **Add Annotation**; **Record Voice Over**; and timeline zoom controls with **Fit Timeline**.",
        },
        {
          type: "p",
          text: "Right-click an empty spot in a lane to add a block at that time, or right-click a block to change or delete it. See [Timeline](/docs/editing/timeline).",
        },
        {
          type: "callout",
          tone: "tip",
          text: "Most editing is faster from the keyboard: Space to play, ⌘B to split, B for the slice tool. See [Keyboard shortcuts](/docs/getting-started/keyboard-shortcuts).",
        },
      ],
      related: ["editing", "editing/timeline", "getting-started/keyboard-shortcuts", "web-app/editor"],
      lastModified: CHECKED,
    },
    {
      slug: "getting-started/keyboard-shortcuts",
      title: "CaptureCat keyboard shortcuts for Mac",
      navTitle: "Keyboard shortcuts",
      description:
        "Every keyboard shortcut in CaptureCat for Mac: recording, screenshots, the library, the editor timeline and preview, with exact key combinations.",
      summary:
        "Menu shortcuts work while CaptureCat is the active app; timeline keys work when the timeline has focus. The only system-wide shortcuts are ⇧⌘3, ⇧⌘4 and ⇧⌘5, and only when CaptureCat is your default screenshot tool.",
      platforms: ["mac"],
      blocks: [
        { type: "h2", text: "Screenshots (system-wide)" },
        {
          type: "p",
          text: "These work in any app once you turn on **Settings → General → Default screenshot tool** and allow Accessibility access. See [Screenshots](/docs/recording/screenshots).",
        },
        {
          type: "shortcuts",
          rows: [
            ["⇧⌘3", "Screenshot the main display and open it in the editor"],
            ["⇧⌘4", "Open the capture bar"],
            ["⇧⌘5", "Open the capture bar"],
          ],
        },
        { type: "h2", text: "App" },
        {
          type: "shortcuts",
          rows: [
            ["⇧⌘N", "New Recording"],
            ["⌘O", "Browse Captures"],
            ["⌥⌘N", "New Note from Clipboard"],
            ["⌘,", "Settings"],
            ["⌘W", "Close window"],
            ["⌘M", "Minimize"],
            ["⌃⌘F", "Enter Full Screen"],
            ["⌘H", "Hide CaptureCat"],
            ["⌥⌘H", "Hide Others"],
            ["⌘Q", "Quit CaptureCat"],
          ],
        },
        { type: "h2", text: "Recording" },
        {
          type: "shortcuts",
          rows: [
            ["Esc", "Cancel window picking or area selection"],
            ["Return", "Capture the address typed in the URL field"],
          ],
        },
        { type: "h2", text: "Library" },
        {
          type: "shortcuts",
          rows: [
            ["⌘K", "Search Captures"],
            ["⌘1", "Show All Captures"],
            ["⌘2", "Show Videos"],
            ["⌘3", "Show Images"],
            ["⌘4", "Show Notes"],
            ["Delete", "Delete the selected captures"],
          ],
        },
        { type: "h2", text: "Editor" },
        {
          type: "shortcuts",
          rows: [
            ["⌥⌘I", "Toggle Inspector"],
            ["⌘-", "Zoom the preview out"],
            ["⌘=", "Zoom the preview in"],
            ["⌘Z", "Undo"],
            ["⇧⌘Z", "Redo"],
          ],
        },
        { type: "h2", text: "Timeline" },
        {
          type: "p",
          text: "The timeline has focus when the editor opens and whenever you click it.",
        },
        {
          type: "shortcuts",
          rows: [
            ["Space", "Play or pause"],
            ["← / →", "Step back or forward one frame (1/30 s)"],
            ["⇧← / ⇧→", "Step back or forward one second"],
            ["Home", "Go to the start of the trimmed video"],
            ["End", "Go to the end of the trimmed video"],
            ["⌘B", "Split at Playhead"],
            ["B", "Turn the slice tool on or off (click a clip to split it there)"],
            ["⌘D", "Duplicate the selected block"],
            ["Delete", "Delete the selected block"],
            ["Esc", "Deselect the selected clip"],
          ],
        },
        {
          type: "callout",
          tone: "note",
          text: "CaptureCat has no global shortcut to start or stop a screen recording. Use the recording bar or the menu bar icon, which has **Pause Recording**, **Resume Recording** and **Stop Recording** while a recording is running.",
        },
      ],
      related: ["getting-started/editor-tour", "editing/timeline", "recording/screenshots", "library"],
      lastModified: CHECKED,
    },
  ],
};
