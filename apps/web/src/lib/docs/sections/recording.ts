import type { DocSection } from "../types";

/**
 * Checked against apps/macos/CaptureCat: RecordingPanelViewController (tabs,
 * chips, gear menu, countdown and limit presets, in-recording controls,
 * dialogs, URL and still capture), RecordingPanelMetrics (RecordingSourceTab),
 * RecordingPanelKit (CaptureMode), AppState (defaults, start/stop, auto zoom,
 * openWebCapture, ⇧⌘3 still), ScreenRecorder (60 fps, cursor hidden, P3,
 * macOS 15 mic), DeviceRecorder, CameraManager, CameraFloatPreview,
 * CountdownOverlayController, Area/WindowSelectionOverlay, KeystrokeTracker,
 * KeySoundPlayer, ClickSoundPlayer, KeystrokeOverlay, ScreenshotHotkeys,
 * WebPageCapture (presets), WebOptionsEditor, RemoteScreenshotClient,
 * SettingsWindowController, ProjectSettings defaults, the Camera / Cursor /
 * Audio inspector panes, ExportSheetController (Image (PNG) | Video (MP4));
 * apps/api routes/screenshot.ts + lib/screenshot/params.ts (webCapture gate,
 * SSRF guard) and migration 0008 (webCapture: Pro only).
 */
const CHECKED = "2026-10-07";

export const RECORDING: DocSection = {
  id: "recording",
  title: "Recording",
  description: "Displays, windows, areas, iPhone and iPad, camera, audio and shortcuts.",
  pages: [
    {
      slug: "recording",
      title: "Record your Mac screen: a display, a window or an area",
      navTitle: "Overview",
      description:
        "How to screen record on a Mac with CaptureCat: a full display, one window or a dragged area at 60 fps, with countdown, pause, restart and time limits.",
      summary:
        "Open the recording bar from the CaptureCat menu bar icon, pick **Display**, **Window** or **Area**, and press the red record button. CaptureCat records at 60 fps at your screen's full resolution, keeps your clicks and cursor path as editable data, and opens the editor when you stop.",
      platforms: ["mac"],
      blocks: [
        { type: "h2", text: "The recording bar" },
        {
          type: "p",
          text: "Choose **New Recording...** from the CaptureCat menu bar icon (⇧⌘N while CaptureCat is active) to open the recording bar. On the left, **Record** and **Screenshot** choose between a video and a [screenshot](/docs/recording/screenshots). Next to them are the source tabs:",
        },
        {
          type: "table",
          head: ["Tab", "Records", "How you pick it"],
          rows: [
            ["**Display**", "A whole screen", "Choose a screen from **Choose Display**."],
            ["**Window**", "One window, without its shadow", "Hover over windows and click one, or pick it from **Choose Window**."],
            ["**Area**", "A rectangle you drag out", "Choose the screen, click **Select Area** and drag."],
            ["**iPhone**", "A connected iPhone or iPad", "See [iPhone and iPad](/docs/recording/iphone-and-ipad)."],
            ["**URL**", "A web page, as a screenshot", "See [Web page capture](/docs/recording/web-page-capture)."],
          ],
        },
        {
          type: "p",
          text: "The rest of the bar sets up audio and camera: the **Mic · No Cam** chip picks a microphone and camera (see [Audio](/docs/recording/audio) and [Camera](/docs/recording/camera)), and the **Audio On** chip turns system audio on or off. The red record button starts recording; the **×** on the far left closes the bar.",
        },
        { type: "h2", text: "Record a display" },
        {
          type: "p",
          text: "Select **Display**, pick the screen in **Choose Display** if you have more than one, and press record.",
        },
        { type: "h2", text: "Record a single window" },
        {
          type: "p",
          text: "Select **Window**. The screen dims and the window under your pointer is highlighted; click the one you want. Press Esc to cancel and pick from the **Choose Window** list instead. The chosen window comes to the front, ready to record. CaptureCat records just that window's content, without the shadow around it.",
        },
        { type: "h2", text: "Record part of the screen" },
        {
          type: "p",
          text: "Select **Area**, pick the screen in **Choose Display**, then click **Select Area** and drag a rectangle. The chip then shows the area's size, such as **Area 1280x720**. Press Esc to cancel the selection. The area must be at least 10 by 10 points.",
        },
        { type: "h2", text: "Recording options" },
        {
          type: "p",
          text: "The gear button in the bar holds the recording options:",
        },
        {
          type: "table",
          head: ["Option", "Choices", "Default"],
          rows: [
            ["**Capture Shortcuts (⌘⇧S overlay)**", "On or off. Records the shortcuts you press so the editor can show them. See [Keystrokes](/docs/recording/keystrokes).", "Off"],
            ["**Recording Countdown**", "Off, 3s, 5s, 10s", "3s"],
            ["**Duration Limit**", "No Limit, 15s, 30s, 1 min, 2 min, 5 min, 10 min, or **Custom…**", "No Limit"],
            ["**Settings…**", "Opens CaptureCat's settings.", ""],
          ],
        },
        {
          type: "p",
          text: "The countdown appears in the middle of the screen you're about to record. It never appears in the video, and clicks pass through it, so you can arrange windows while it counts down. The duration limit counts recorded time, so paused time doesn't count, and recording stops by itself when it's reached. You can set the same defaults under **Settings → Recording** (**Countdown** and **Maximum duration**).",
        },
        { type: "h2", text: "While you record", id: "while-you-record" },
        {
          type: "table",
          head: ["Control", "What it does"],
          rows: [
            ["Timer and source", "How long you've recorded, and what's being recorded."],
            ["Pause / resume", "Pauses the recording; click again to carry on. Paused time is left out of the video."],
            ["Switch source", "Moves the recording to another display or to a connected iPhone or iPad without stopping. The parts are joined into one project when you stop."],
            ["Restart", "After you confirm **Restart**, deletes the current take and starts again from 0:00."],
            ["Stop", "Ends the recording and opens it in the editor."],
            ["Delete", "After you confirm **Delete**, stops and permanently deletes the current recording."],
          ],
        },
        {
          type: "p",
          text: "The CaptureCat menu bar icon also has **Pause Recording** (or **Resume Recording**) and **Stop Recording** while a recording is running.",
        },
        { type: "h2", text: "What CaptureCat records" },
        {
          type: "list",
          items: [
            "**Video** at up to 60 fps at the screen's native resolution, in the Display P3 color space.",
            "**Your cursor, clicks and scrolls as data.** The pointer is not burned into the video; the editor draws it, so you can resize, smooth or hide it later. See [Cursor](/docs/editing/cursor).",
            "**Keystroke timing**, if you've allowed Input Monitoring. Only when keys were pressed is stored, never what you typed. See [Keystrokes](/docs/recording/keystrokes).",
            "**System audio and your microphone** on separate tracks. See [Audio](/docs/recording/audio).",
            "**Your camera** on its own track. See [Camera](/docs/recording/camera).",
          ],
        },
        {
          type: "p",
          text: "CaptureCat leaves its own windows out of the recording: the recording bar, the countdown and the live camera preview never show up in the video.",
        },
        { type: "h2", text: "When you stop" },
        {
          type: "p",
          text: "The recording is saved as a project and opens in the editor. With **Settings → General → Auto zoom new recordings** on (the default), CaptureCat has already added zooms based on your clicks and typing. See [Auto zoom](/docs/editing/auto-zoom) and the [editor tour](/docs/getting-started/editor-tour).",
        },
        {
          type: "callout",
          tone: "note",
          title: "Recording in a browser",
          text: "The CaptureCat web app records a display, window or browser tab from Chrome, Edge, Safari or Firefox. See [Record in the browser](/docs/web-app/record).",
        },
      ],
      faqs: [
        {
          question: "How do I record only part of my screen on a Mac?",
          answer:
            "In CaptureCat's recording bar select Area, click Select Area and drag a rectangle over the part you want, then press record. To record one app, use the Window tab instead.",
        },
        {
          question: "Can I pause a screen recording on Mac?",
          answer:
            "Yes. Click the pause button in CaptureCat's recording bar, or choose Pause Recording from the menu bar icon. Paused time is left out of the video.",
        },
        {
          question: "Is there a time limit on recordings?",
          answer:
            "No, unless you set one. Duration Limit in the recording bar's gear menu stops recording automatically after 15 seconds to 10 minutes, or a custom length.",
        },
        {
          question: "Does the mouse pointer appear in the recording?",
          answer:
            "Yes, but CaptureCat records it separately from the video and draws it in the editor, so you can make it bigger, smooth its movement, change its style or hide it.",
        },
      ],
      related: ["getting-started/first-recording", "recording/audio", "recording/camera", "editing/auto-zoom"],
      lastModified: CHECKED,
    },
    {
      slug: "recording/iphone-and-ipad",
      title: "Record your iPhone or iPad screen on a Mac",
      navTitle: "iPhone and iPad",
      description:
        "How to record an iPhone or iPad screen on your Mac over USB with CaptureCat, with device audio, your Mac mic, and a realistic device frame in the editor.",
      summary:
        "Connect the iPhone or iPad with a USB cable, unlock it and tap **Trust**, then pick it on the **iPhone** tab of the recording bar and press record. CaptureCat records the device's screen and sound, and the editor shows it inside a device frame.",
      platforms: ["mac"],
      blocks: [
        { type: "h2", text: "What you need" },
        {
          type: "list",
          items: [
            "A USB cable between the iPhone or iPad and your Mac. Wireless recording isn't supported.",
            "The device unlocked, and **Trust** tapped when it asks whether to trust this computer.",
            "Camera permission for CaptureCat. macOS treats a connected device's screen as a video device, so CaptureCat asks for Camera access the first time you record one.",
          ],
        },
        { type: "h2", text: "Record the device" },
        {
          type: "steps",
          steps: [
            {
              title: "Connect and unlock",
              text: "Plug in the device, unlock it, and tap **Trust** if asked.",
            },
            {
              title: "Choose the iPhone tab",
              text: "Open the recording bar from the menu bar icon (**New Recording...**), make sure **Record** is selected, and click **iPhone**.",
            },
            {
              title: "Pick the device",
              text: "Choose it from **Choose Device**. The list refreshes each time you open it. If it's empty, it reads: Connect an iPhone or iPad via USB, unlock it, and tap “Trust”.",
            },
            {
              title: "Record",
              text: "Press the red record button. A live view of the device appears in a floating window on your Mac while you record.",
            },
            {
              title: "Stop",
              text: "Click stop. The editor opens with the recording inside a device frame.",
            },
          ],
        },
        { type: "h2", text: "Audio" },
        {
          type: "p",
          text: "CaptureCat records the device's own sound, and your Mac's microphone if one is selected in the **Mic · No Cam** chip, so you can narrate while you demo the app.",
        },
        { type: "h2", text: "In the editor" },
        {
          type: "list",
          items: [
            "**Device frame:** turn **iPhone / iPad Frame** on or off in the **Background** pane, under **Frame**. It is on for new projects.",
            "**Taps:** a device recording has no Mac cursor, so auto zoom has no clicks to follow. Add **Tap Indicator** annotations (a looping touch ripple) to show where you tapped. See [Annotations](/docs/editing/annotations).",
            "**Zooms:** add zoom blocks by hand from the timeline's **Zoom** menu. See [Auto zoom](/docs/editing/auto-zoom).",
            "**Shape:** choose **9:16** in the editor's Aspect menu for a vertical social video. See [Framing](/docs/editing/framing).",
          ],
        },
        { type: "h2", text: "Switch between your Mac and the device" },
        {
          type: "p",
          text: "During a screen recording, click the switch source button in the recording bar and choose a device under **iPhone / iPad**, or a screen under **Displays**. Recording carries on, and the parts are joined into one project when you stop.",
        },
        { type: "h2", text: "Show a device as an overlay" },
        {
          type: "p",
          text: "To show an iPhone or iPad in a corner of a Mac screen recording, choose it under **Camera / iPhone Overlay** in the **Mic · No Cam** chip. It is recorded on the camera track, like a webcam. See [Camera](/docs/recording/camera).",
        },
        {
          type: "callout",
          tone: "note",
          text: "**Screenshot** mode doesn't offer the iPhone tab, because a connected device is a live video source. For a still, take the screenshot on the device itself.",
        },
      ],
      faqs: [
        {
          question: "How do I record my iPhone screen on my Mac?",
          answer:
            "Connect the iPhone to your Mac with a USB cable, unlock it and tap Trust. In CaptureCat's recording bar choose the iPhone tab, pick the phone from Choose Device and press record.",
        },
        {
          question: "Can CaptureCat record an iPhone wirelessly?",
          answer: "No. iPhone and iPad recording works over a USB cable.",
        },
        {
          question: "Why doesn't my iPhone show up in Choose Device?",
          answer:
            "Check the cable, unlock the device and tap Trust on it, then open Choose Device again; the list refreshes each time. Also make sure CaptureCat has Camera permission in System Settings → Privacy & Security → Camera.",
        },
      ],
      related: ["recording", "editing/framing", "editing/annotations", "recording/camera"],
      lastModified: CHECKED,
    },
    {
      slug: "recording/camera",
      title: "Record your screen and webcam at the same time on Mac",
      navTitle: "Camera bubble",
      description:
        "Add a webcam bubble to a Mac screen recording with CaptureCat. The camera records on its own track, so you can restyle, move or hide it after recording.",
      summary:
        "Pick a camera under **Camera / iPhone Overlay** in the recording bar's **Mic · No Cam** chip, and a draggable preview bubble appears while you record. The camera is saved as its own track, so its shape, position and look are all set in the editor afterwards.",
      platforms: ["mac"],
      blocks: [
        { type: "h2", text: "Turn on the camera" },
        {
          type: "steps",
          steps: [
            {
              title: "Open the camera menu",
              text: "In the recording bar, click the **Mic · No Cam** chip.",
            },
            {
              title: "Pick a camera",
              text: "Under **Camera / iPhone Overlay**, choose your camera. The chip changes to **Mic · Cam** (or **No Mic · Cam**). Choose **No Overlay** to turn the camera off.",
            },
            {
              title: "Place the preview",
              text: "A live preview bubble appears. Drag it anywhere on any screen; CaptureCat remembers where you left it. Right-click it to choose **Small**, **Medium** or **Large**.",
            },
            {
              title: "Record",
              text: "Press record. The preview bubble is only for you: it never appears in the recording.",
            },
          ],
        },
        {
          type: "p",
          text: "The camera list includes your Mac's built-in camera, external webcams, and connected iPhones or iPads (shown as their screen). CaptureCat needs Camera permission; see [Install and permissions](/docs/getting-started/install).",
        },
        { type: "h2", text: "Style the bubble in the editor" },
        {
          type: "p",
          text: "Because the camera is a separate track, everything about the bubble is set in the editor's **Camera** pane and can be changed at any time:",
        },
        {
          type: "table",
          head: ["Section", "Settings"],
          rows: [
            ["**Camera Overlay**", "**Show Camera**, **Position** (Top Left, Top Right, Bottom Left, Bottom Right; default Bottom Right), **Shape** (Circle, Squircle, Rounded Rectangle, Square; default Circle), orientation for the rounded shapes (Auto, Vertical, Wide), **Mirror Camera** and **Size**."],
            ["**Adjust**", "**Brightness**, **Contrast**, **Saturation**, **Hue**, a look (None, Mono, Noir, Warm, Cool, Fade) and **Ring Light**."],
            ["**Style**", "**Corner Radius**, **Border**, **Border Color**, **Opacity** and a 3D tilt."],
            ["**Name Tag**", "A pill with your **Name** and **Role / company**, with **Tag Position**, **Text Color** and **Tag Fill**."],
          ],
        },
        {
          type: "p",
          text: "You can also drag the bubble directly on the preview to put it anywhere, not just in a corner.",
        },
        { type: "h2", text: "Change the layout for part of the video" },
        {
          type: "p",
          text: "From the timeline's **Zoom** menu, add a camera layout for a span of the video:",
        },
        {
          type: "list",
          items: [
            "**Camera: Full Screen**: the webcam fills the card, for a talking-head moment.",
            "**Camera: Side by Side**: the screen shrinks to the left and the webcam fills the right.",
            "**Camera: Hide**: no webcam for that span, screen only.",
          ],
        },
        {
          type: "p",
          text: "These spans appear on the timeline and can be moved and resized like other blocks. They are only available when the project has recorded camera video. See [Timeline](/docs/editing/timeline).",
        },
      ],
      faqs: [
        {
          question: "How do I record my screen and webcam at the same time on a Mac?",
          answer:
            "In CaptureCat's recording bar click the Mic · No Cam chip and pick a camera under Camera / iPhone Overlay, then press record. The camera is recorded on its own track and shown as a bubble you can style in the editor.",
        },
        {
          question: "Can I move or remove the webcam after recording?",
          answer:
            "Yes. Drag the bubble on the editor's preview, change its corner, shape and size in the Camera pane, turn off Show Camera, or hide it for part of the video with Camera: Hide.",
        },
        {
          question: "Does the camera preview show up in the recording?",
          answer:
            "No. The floating preview is excluded from the screen capture. The camera appears in the video only where the editor places it.",
        },
      ],
      related: ["recording", "recording/audio", "recording/iphone-and-ipad", "editing/framing"],
      lastModified: CHECKED,
    },
    {
      slug: "recording/audio",
      title: "Record Mac system audio and your microphone",
      navTitle: "System audio and microphone",
      description:
        "Record your Mac's system audio and microphone with CaptureCat, with no BlackHole or virtual driver. Separate tracks, Voice Isolation, and levels in the editor.",
      summary:
        "CaptureCat records the sound your Mac plays and your microphone directly, with no extra audio driver, on separate tracks. Turn system audio on with the **Audio On** chip, pick a mic in the **Mic · No Cam** chip, and balance the levels later in the editor's **Audio** pane.",
      platforms: ["mac"],
      blocks: [
        { type: "h2", text: "System audio" },
        {
          type: "p",
          text: "The **Audio On** chip in the recording bar records everything your Mac plays: app sounds, a video you're demoing, a call. It is on by default; click it to switch to **Audio Off**. You don't need BlackHole, Soundflower or a Multi-Output Device.",
        },
        { type: "h2", text: "Microphone" },
        {
          type: "steps",
          steps: [
            {
              title: "Open the mic menu",
              text: "Click the **Mic · No Cam** chip in the recording bar.",
            },
            {
              title: "Choose a microphone",
              text: "Under **Microphone**, pick the mic to use. Choose **No Microphone** to record without one.",
            },
            {
              title: "Optional: reduce background noise",
              text: "Click **Voice Isolation & Mic Modes…** to open macOS's microphone mode picker, and choose **Voice Isolation** to filter out background noise.",
            },
          ],
        },
        {
          type: "callout",
          tone: "warning",
          title: "macOS 15 or later",
          text: "Recording the microphone along with the screen needs macOS 15 Sequoia or later. On macOS 14 Sonoma, screen recordings are made without the mic; record your narration afterwards with a voice-over in the editor. Microphone recording with an [iPhone or iPad](/docs/recording/iphone-and-ipad) and voice-overs work on macOS 14.",
        },
        { type: "h2", text: "Separate tracks" },
        {
          type: "p",
          text: "System audio and the microphone are kept apart, so a loud app can't drown your voice: you set each one's level after recording. Camera video is recorded on its own track too.",
        },
        { type: "h2", text: "Levels in the editor" },
        {
          type: "p",
          text: "The editor's **Audio** pane has a volume slider for each source:",
        },
        {
          type: "table",
          head: ["Slider", "Controls", "Range"],
          rows: [
            ["**System Audio**", "Sound your Mac played", "0 to 100%"],
            ["**Microphone**", "Your mic", "0 to 100%"],
            ["**Voice Over**", "Narration recorded in the editor", "0 to 150%"],
          ],
        },
        {
          type: "p",
          text: "All three start at 100%. See [Editing audio](/docs/editing/audio).",
        },
        { type: "h2", text: "Add narration afterwards" },
        {
          type: "p",
          text: "Click **Record Voice Over** (the microphone button) in the timeline toolbar. The video plays while you narrate; click the button again to stop. The clip lands on the **VOICE** lane. Recording a voice-over needs Microphone permission.",
        },
        {
          type: "callout",
          tone: "tip",
          text: "Want typing and click sounds without recording them? CaptureCat can synthesize them from your recorded keystrokes and clicks. See [Keystrokes](/docs/recording/keystrokes).",
        },
      ],
      faqs: [
        {
          question: "How do I record internal audio on a Mac without BlackHole?",
          answer:
            "Use a recorder that captures system audio directly. In CaptureCat, leave the Audio On chip on in the recording bar; the sound your Mac plays is recorded with the screen, on its own track, with no virtual audio driver.",
        },
        {
          question: "Why wasn't my microphone recorded?",
          answer:
            "Check that a mic is selected under Microphone in the Mic · No Cam chip (not No Microphone), that CaptureCat has Microphone permission, and that your Mac runs macOS 15 or later, which screen recording with a mic requires.",
        },
        {
          question: "Can I change the volume of system audio and my voice separately?",
          answer:
            "Yes. They are recorded on separate tracks, and the editor's Audio pane has its own slider for System Audio, Microphone and Voice Over.",
        },
      ],
      related: ["editing/audio", "recording/keystrokes", "recording", "getting-started/install"],
      lastModified: CHECKED,
    },
    {
      slug: "recording/keystrokes",
      title: "Show keystrokes and add typing sounds to screen recordings",
      navTitle: "Keystrokes and key sounds",
      description:
        "Show the keyboard shortcuts you press as an on-screen pill, and add synthesized typing and click sounds to a Mac screen recording with CaptureCat.",
      summary:
        "CaptureCat records when you press keys, never what you type, and can add typing sounds from that timing in the editor. Turn on **Capture Shortcuts** before recording and it also records shortcuts that use ⌘, ⌃ or ⌥, which the editor can show as an on-screen pill.",
      platforms: ["mac"],
      blocks: [
        { type: "h2", text: "What CaptureCat records" },
        {
          type: "list",
          items: [
            "**Always (with Input Monitoring):** the moment of each key press and a rough category (a key, space, return, delete or a modifier), plus scroll ticks. Never the key itself. This drives typing sounds, and lets auto zoom hold steady while you type or scroll.",
            "**Only with Capture Shortcuts on:** key combinations that include ⌘, ⌃ or ⌥, such as ⌘⇧S, and which app received them. Plain typing is never identified, even with this on, so passwords and messages can't end up in a video.",
          ],
        },
        { type: "h2", text: "Allow Input Monitoring" },
        {
          type: "p",
          text: "Keystroke capture needs macOS's Input Monitoring permission. CaptureCat asks for it when you turn on **Capture Shortcuts**, or when you click **Request Permission** under **Keyboard Sounds** in the editor's **Cursor** pane. You can also turn it on in **System Settings → Privacy & Security → Input Monitoring**. Without it, recordings work normally but have no keystroke data.",
        },
        { type: "h2", text: "Show shortcuts on screen" },
        {
          type: "steps",
          steps: [
            {
              title: "Turn on Capture Shortcuts",
              text: "Before recording, open the gear menu in the recording bar and turn on **Capture Shortcuts (⌘⇧S overlay)**. It stays on for later recordings until you turn it off.",
            },
            {
              title: "Record",
              text: "Use your shortcuts as normal while you record.",
            },
            {
              title: "Style the overlay",
              text: "In the editor, open the **Cursor** pane and find **Shortcut Overlay**. **Show Shortcut Overlay** is on by default. Set **Size**, **Position** (Bottom Center, Bottom Left, Bottom Right or Top Center) and **Animation** (Slide Up, Fade or Pop).",
            },
          ],
        },
        {
          type: "p",
          text: "For window recordings, **Only Recorded App** (on by default) hides shortcuts you pressed in other apps during the recording. The pill appears in the preview and in the exported file.",
        },
        {
          type: "callout",
          tone: "note",
          text: "Capture Shortcuts has to be on when you record. A recording made without it has no shortcut data, and the Shortcut Overlay section says so.",
        },
        { type: "h2", text: "Keyboard and click sounds" },
        {
          type: "p",
          text: "CaptureCat can play a synthesized sound at each recorded key press or click. Both are off by default and are set in the editor's **Cursor** pane:",
        },
        {
          type: "table",
          head: ["Setting", "Sounds", "Default"],
          rows: [
            ["**Keyboard Sounds**", "Thock, Clacky, Soft, Cream, Blue Click, Typewriter, Membrane", "Thock, volume 60%"],
            ["**Click Sound** (under **Click Effect**)", "Soft Tick, Clicky, Deep, Pop", "Soft Tick, volume 70%"],
          ],
        },
        {
          type: "p",
          text: "Click **Test** to hear the selected sound. The sounds are generated in the app, so there are no audio files involved, and they play in the preview and in the exported file. Each key press varies slightly in pitch so fast typing sounds natural.",
        },
        {
          type: "p",
          text: "Keyboard sounds need keystroke data, so they only work on recordings made with Input Monitoring allowed. Click sounds work on any screen recording, because clicks are always recorded.",
        },
      ],
      faqs: [
        {
          question: "How do I show keyboard shortcuts in a screen recording on Mac?",
          answer:
            "In CaptureCat, turn on Capture Shortcuts (⌘⇧S overlay) in the recording bar's gear menu before you record, and allow Input Monitoring. The editor then shows each shortcut as a pill, styled in the Cursor pane under Shortcut Overlay.",
        },
        {
          question: "Does CaptureCat record what I type?",
          answer:
            "No. It stores only when keys were pressed. With Capture Shortcuts on, it also stores key combinations that use ⌘, ⌃ or ⌥; ordinary typing is never identified.",
        },
        {
          question: "How do I add keyboard sounds to a screen recording?",
          answer:
            "Record with Input Monitoring allowed, then turn on Keyboard Sounds in the editor's Cursor pane and pick a sound such as Thock or Typewriter. The sounds are synthesized at each recorded key press and included in the export.",
        },
      ],
      related: ["editing/cursor", "recording/audio", "editing/auto-zoom", "recording"],
      lastModified: CHECKED,
    },
    {
      slug: "recording/web-page-capture",
      title: "Capture a web page screenshot by URL on Mac",
      navTitle: "Web page capture",
      description:
        "Capture any public web page by URL at desktop, tablet or mobile size, full page height, in dark mode, without cookie banners or chat widgets. A Pro feature.",
      summary:
        "Choose the **URL** tab in CaptureCat's recording bar, type an address and press Return. CaptureCat renders the page at the device size you pick and opens it in the editor as an image, ready to frame and export. Web page capture is part of CaptureCat Pro.",
      platforms: ["mac"],
      plan: "pro",
      blocks: [
        {
          type: "steps",
          steps: [
            {
              title: "Open the URL tab",
              text: "Open the recording bar from the menu bar icon and click **URL**. An address field replaces the source controls.",
            },
            {
              title: "Pick a device",
              text: "Click the device chip next to the field: **Desktop (1440pt)**, **Tablet (834pt)** or **Mobile (390pt)**. The page is laid out at that width, the way that device would see it. Desktop is the default.",
            },
            {
              title: "Set the options",
              text: "Click the gear next to the device chip to choose the height, dark mode, what to hide and a delay. See the table below.",
            },
            {
              title: "Capture",
              text: "Type the address (for example `stripe.com`) and press Return. When the page is ready, the editor opens with it as an image project named after the site.",
            },
          ],
        },
        { type: "h2", text: "Options" },
        {
          type: "table",
          head: ["Option", "Choices", "Default"],
          rows: [
            ["**Height**", "**Viewport** (one screen), **Full ×4** (the page, up to four screens tall), **Entire Page**", "Viewport"],
            ["**Dark Mode**", "Uses the site's own dark theme when it has one", "Off"],
            ["**Hide Cookie Banners**", "Removes cookie consent banners", "Off"],
            ["**Hide Chat Widgets**", "Removes support chat bubbles", "Off"],
            ["**Reduce Motion**", "Pauses page animations before the capture", "Off"],
            ["**Delay Before Capture**", "None, 1s, 2s, 5s. Gives lazy-loading content time to appear.", "None"],
          ],
        },
        {
          type: "p",
          text: "Your choices are remembered. **Settings → Web Capture** has the same device, delay, dark mode, hide and reduce motion settings. Desktop and tablet captures come out at 2x pixel density, mobile at 3x.",
        },
        { type: "h2", text: "In the editor" },
        {
          type: "p",
          text: "A web capture is an ordinary image project: put it on a background, add annotations or a zoom, and export it as **Image (PNG)**, or switch the top bar to **Video** to turn it into a short clip. See [Screenshots](/docs/recording/screenshots) and [Framing](/docs/editing/framing).",
        },
        { type: "h2", text: "How pages are rendered" },
        {
          type: "list",
          items: [
            "The page is rendered by CaptureCat's servers in Chromium, not in your own browser. You get what a signed-out visitor sees, so pages behind a login can't be captured this way. Record them in a browser window with the **Window** tab instead.",
            "Only public addresses work. `localhost`, `.local` names and private IP addresses are refused.",
            "You need to be signed in, on a plan that includes web capture. Each capture counts toward your plan's monthly allowance; see [Plans](/docs/account/plans).",
          ],
        },
        { type: "h2", text: "Errors" },
        {
          type: "table",
          head: ["Message", "What to do"],
          rows: [
            ["Sign in to capture web pages.", "Sign in from the CaptureCat menu bar icon or **Settings → Account**."],
            ["Web capture requires a CaptureCat Pro plan.", "Upgrade to Pro. See [Plans](/docs/account/plans)."],
            ["\"…\" is not a valid web address.", "Check the address. You can leave out `https://`."],
            ["The CaptureCat capture service could not be reached.", "Check your internet connection and try again."],
          ],
        },
        {
          type: "callout",
          tone: "pro",
          text: "Web page capture by URL is included in CaptureCat Pro. Recording and screenshotting your own screen, including a browser window, is free.",
        },
      ],
      faqs: [
        {
          question: "How do I take a full-page screenshot of a website on a Mac?",
          answer:
            "In CaptureCat, choose the URL tab in the recording bar, set Height to Full ×4 or Entire Page in the options, type the address and press Return. The page opens in the editor as an image you can frame and export as PNG.",
        },
        {
          question: "Can I capture the mobile version of a website?",
          answer:
            "Yes. Pick Mobile (390pt) or Tablet (834pt) in the device chip before capturing, and the page is laid out at that width with a matching browser identity, at 3x or 2x pixel density.",
        },
        {
          question: "Is web page capture free?",
          answer: "No. Capturing a page by URL is a CaptureCat Pro feature. Recording your own screen and taking screenshots of it are free.",
        },
      ],
      related: ["recording/screenshots", "editing/framing", "account/plans", "recording"],
      lastModified: CHECKED,
    },
    {
      slug: "recording/screenshots",
      title: "Take screenshots on Mac with CaptureCat",
      navTitle: "Screenshots",
      description:
        "Take a screenshot of a display, window or area with CaptureCat, frame it on a background in the editor, export a PNG, or replace ⇧⌘3, ⇧⌘4 and ⇧⌘5.",
      summary:
        "Switch the recording bar to **Screenshot**, pick a display, window or area, and click the camera button. The screenshot opens in the editor, where you can add a background, annotations and zooms, then export it as a PNG or a short MP4.",
      platforms: ["mac"],
      blocks: [
        { type: "h2", text: "Take a screenshot" },
        {
          type: "steps",
          steps: [
            {
              title: "Switch to Screenshot",
              text: "In the recording bar, click **Screenshot** on the left.",
            },
            {
              title: "Pick a source",
              text: "Choose **Display**, **Window** or **Area** and select what to capture, the same way as for a recording. See [Recording](/docs/recording). The **URL** tab captures a web page; see [Web page capture](/docs/recording/web-page-capture).",
            },
            {
              title: "Capture",
              text: "Click the blue camera button. The screenshot opens in the editor as an image project.",
            },
          ],
        },
        {
          type: "p",
          text: "The **iPhone** tab isn't available in Screenshot mode, because a connected device is a live video source.",
        },
        { type: "h2", text: "Edit and export" },
        {
          type: "list",
          items: [
            "Add a background, padding, rounded corners and a shadow in the **Background** pane. See [Framing](/docs/editing/framing).",
            "Add arrows, text, callouts and shapes, or blur private details. See [Annotations](/docs/editing/annotations) and [Privacy](/docs/editing/privacy).",
            "The top bar's **Image** / **Video** switch keeps it a still image, or turns it into a short video you can add zooms and motion to.",
            "Click **Export…** and choose **Image (PNG)** or **Video (MP4)**.",
          ],
        },
        { type: "h2", text: "Use CaptureCat for ⇧⌘3, ⇧⌘4 and ⇧⌘5" },
        {
          type: "p",
          text: "Turn on **Settings → General → Default screenshot tool** (or choose **Yes, use CaptureCat for screenshots** during setup) and CaptureCat takes over the macOS screenshot shortcuts:",
        },
        {
          type: "shortcuts",
          rows: [
            ["⇧⌘3", "Screenshot the main display and open it in the editor"],
            ["⇧⌘4", "Open the capture bar"],
            ["⇧⌘5", "Open the capture bar"],
          ],
        },
        {
          type: "p",
          text: "This needs Accessibility access, because CaptureCat has to catch the keys before macOS does. When you turn the setting on, CaptureCat opens **System Settings → Privacy & Security → Accessibility**; turn CaptureCat on there. Without it, the macOS screenshot shortcuts keep working as before. Turn the setting off to give them back to macOS.",
        },
      ],
      faqs: [
        {
          question: "Can I replace the Mac screenshot shortcut with another app?",
          answer:
            "Yes, with CaptureCat. Turn on Default screenshot tool in Settings → General and allow Accessibility access; ⇧⌘3 then captures the main display and ⇧⌘4 or ⇧⌘5 opens CaptureCat's capture bar.",
        },
        {
          question: "How do I put a screenshot on a background on a Mac?",
          answer:
            "Take the screenshot with CaptureCat, or capture it in Screenshot mode, and it opens in the editor. Pick a gradient, color, wallpaper or your own image in the Background pane, then export as PNG.",
        },
      ],
      related: ["recording", "recording/web-page-capture", "editing/framing", "getting-started/keyboard-shortcuts"],
      lastModified: CHECKED,
    },
  ],
};
