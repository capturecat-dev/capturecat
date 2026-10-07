import type { DocSection } from "../types";

/**
 * Checked against apps/macos/CaptureCat: Views/Editor (TimelineViewController,
 * TimelineCanvasView, VideoTrackRowNative, VoiceTrackRowNative, InspectorTab,
 * InspectorKit/*PaneAppKit), Views/AppKitSurfaces (EditorShellViewController,
 * EditorPlaybackController, SettingsWindowController), Models (ProjectSettings,
 * ZoomRegion, TiltRegion, Annotation, BlurRegion, FocusRegion, HighlightRegion,
 * AspectRatio, SubtitlePreset, SubtitleSegment, VideoSpeedRegion), Services
 * (AutoZoomGenerator, AutoZoomApplier, TranscriptionService, ProjectAudioMix,
 * ClickSoundPlayer, KeySoundPlayer); and apps/web/src/editor (ui/shell,
 * ui/panes, transcribe/model.ts, state/subtitleGeneration.ts, record/publish.ts)
 * for web parity. Editing has no plan gate in apps/api/src/lib/plans.ts.
 */
const CHECKED = "2026-10-07";

export const EDITING: DocSection = {
  id: "editing",
  title: "Editing",
  description: "Auto zoom, cursor, framing, annotations, captions, privacy and the timeline.",
  pages: [
    {
      slug: "editing",
      title: "Edit screen recordings in CaptureCat",
      navTitle: "Overview",
      description:
        "How the CaptureCat editor works: non-destructive edits, a preview that matches the export frame for frame, the inspector tabs and the timeline lanes.",
      summary:
        "Every edit in CaptureCat is stored as project data on top of your original recording, so you can change or undo anything later. The preview is drawn from the same math as the exporter, so the frame you see in the editor is the frame in the exported file.",
      platforms: ["mac", "web"],
      blocks: [
        { type: "h2", text: "Non-destructive editing" },
        {
          type: "list",
          items: [
            "**Your recording is never changed.** Zooms, cuts, captions, blurs and styling are saved as project settings next to the original video. Exporting renders a new file.",
            "**The cursor, clicks and keystrokes are data.** The Mac app records them separately from the video, so you can change the cursor's look, size and motion, or add click ripples and sounds, after you record.",
            "**Edits save as you go.** The editor autosaves the project while you work; there is no Save command.",
            "**Timeline edits can be undone.** Adding, moving, trimming, splitting and deleting go on the undo stack (⌘Z, ⇧⌘Z to redo).",
          ],
        },
        { type: "h2", text: "The preview matches the export" },
        {
          type: "p",
          text: "The editor preview and the exporter use the same calculations for zoom, tilt, cursor motion, click ripples, annotations and their animations. Animations are timed from the timeline, not the wall clock, so scrubbing to any moment shows exactly the frame that moment will have in the exported video.",
        },
        { type: "h2", text: "The editor window" },
        {
          type: "table",
          head: ["Area", "What it does"],
          rows: [
            ["Header bar", "**Captures** goes back to your library. The **Aspect** menu sets the output shape. **Export…** renders or shares the video; the sidebar button shows or hides the inspector (⌥⌘I)."],
            ["Preview", "The live video. Drag annotations, zoom targets, blur regions and the subtitle position directly on it."],
            ["Timeline toolbar", "Playback, undo and redo, delete, the **Zoom** and **Focus & Blur** menus, the slice tool, split, **Add Annotation** and **Record Voice Over**."],
            ["Timeline", "Five lanes of blocks you drag, trim and right-click. See [Trim, split, cut and speed up](/docs/editing/timeline)."],
            ["Inspector", "Settings for the whole project, or for the selected block, in nine tabs."],
          ],
        },
        { type: "h2", text: "Inspector tabs" },
        {
          type: "table",
          head: ["Tab", "What you set there"],
          rows: [
            ["**Background**", "Background fill, look adjustments, padding, corners, shadow, device frame and menu bar. See [Framing](/docs/editing/framing)."],
            ["**Cursor**", "Cursor style, size and motion, click ripples, click and keyboard sounds, shortcut overlay. See [Cursor](/docs/editing/cursor)."],
            ["**Camera**", "The webcam bubble. See [Camera](/docs/recording/camera)."],
            ["**Audio**", "Volume for system audio, microphone and voice over. See [Audio](/docs/editing/audio)."],
            ["**Effects**", "The selected zoom, tilt, blur or highlight block, plus Slide, Curtain Unveil, Parallax and Motion Blur. See [Effects](/docs/editing/effects)."],
            ["**Motion**", "How fast zoom and tilt transitions animate, the auto zoom level and follow speed. See [Auto zoom](/docs/editing/auto-zoom)."],
            ["**Subtitles**", "Generate, edit and style captions. See [Captions](/docs/editing/captions)."],
            ["**Brand**", "A logo watermark. See [Framing](/docs/editing/framing#logo-watermark)."],
            ["**Annotate**", "The selected text label, arrow, shape, drawing or tap indicator. See [Annotations](/docs/editing/annotations)."],
          ],
        },
        { type: "h2", text: "Timeline lanes" },
        {
          type: "table",
          head: ["Lane", "Holds"],
          rows: [
            ["VIDEO", "Your recording, its trim, splits and speed changes."],
            ["VOICE", "Voice-over clips you record in the editor."],
            ["EFFECTS", "Zoom and tilt blocks, Slide and Curtain Unveil."],
            ["FOCUS", "Blur, pixelate, highlight, depth focus and camera layout blocks."],
            ["ANNOTATE", "Text labels, arrows, callouts, shapes, drawings and tap indicators."],
          ],
        },
        { type: "h2", text: "On the Mac and on the web" },
        {
          type: "p",
          text: "The same editor runs in your browser with the same tabs, menus and shortcuts, and it opens the same project. See [The web editor](/docs/web-app/editor) and [Mac and web together](/docs/web-app/mac-and-web).",
        },
        {
          type: "callout",
          tone: "note",
          text: "Every editing feature in this section is available on every plan, including Free.",
        },
      ],
      faqs: [
        {
          question: "Does CaptureCat change my original recording when I edit?",
          answer:
            "No. Edits are stored as project settings beside the original video, which is never modified, and exporting always renders a new file.",
        },
        {
          question: "Will my exported video look exactly like the editor preview?",
          answer:
            "Yes. The preview and the exporter share the same math for zooms, cursor, annotations and animations, and both are timed from the timeline, so the exported frame matches the preview frame.",
        },
      ],
      related: ["getting-started/editor-tour", "editing/timeline", "editing/auto-zoom", "export-and-sharing/export"],
      lastModified: CHECKED,
    },
    {
      slug: "editing/auto-zoom",
      title: "Auto zoom and zoom blocks",
      navTitle: "Auto zoom",
      seoTitle: "Auto Zoom for Mac Screen Recordings | CaptureCat Docs",
      description:
        "Add automatic zoom to Mac screen recordings. CaptureCat places zooms from your clicks and typing; adjust depth, speed, aim and cursor follow per block.",
      summary:
        "CaptureCat turns the clicks, typing and pauses it recorded into zoom blocks on the EFFECTS lane, by default as soon as a recording stops. Every zoom is an editable block: set its depth from 0.3x to 6x, aim it, pick how it animates, or let it follow the cursor.",
      platforms: ["mac", "web"],
      blocks: [
        { type: "h2", text: "How Auto Zoom picks moments" },
        {
          type: "list",
          items: [
            "**Clicks.** Single clicks count; click-and-drag selections do not.",
            "**Typing.** Three or more keys pressed less than 1.5 seconds apart, anchored where you clicked into the field.",
            "**Hovering.** The cursor resting in one spot for 0.8 to 4 seconds. A cursor parked longer than that counts as idle.",
            "**Clusters, not single events.** Activity close together in time and space is grouped. A lone click never zooms; a group needs two or more interactions, a typing burst or a hover.",
          ],
        },
        {
          type: "p",
          text: "Each zoom starts 0.35 seconds before the first interaction, holds 0.9 seconds after the last, and lasts at least 1.8 seconds. When the next group is nearby and soon, the camera pans across to it instead of zooming out and back in.",
        },
        { type: "h3", text: "Zoom depth" },
        {
          type: "p",
          text: "Depth starts from **Zoom Level** in the Motion tab (default 2.0x). Tight activity goes 0.4x deeper, or 0.5x with typing; activity spread across the screen goes 0.5x shallower. Auto zooms always land between 1.3x and 2.75x, and the zoomed view never crops past the edge of the recording.",
        },
        { type: "h2", text: "Run Auto Zoom" },
        {
          type: "steps",
          steps: [
            {
              title: "Open the Zoom menu",
              text: "Click the sparkles button (**Zoom**) in the timeline toolbar.",
            },
            {
              title: "Choose Auto Zoom",
              text: "**Auto Zoom** (Generate zooms from cursor movement) adds zoom blocks to the EFFECTS lane.",
            },
            {
              title: "Adjust or remove what you don't want",
              text: "Select a block to edit it in the Effects tab, drag its edges to retime it, or press Delete. ⌘Z undoes the whole Auto Zoom run.",
            },
          ],
        },
        {
          type: "p",
          text: "Running Auto Zoom again replaces only the zooms it generated before. Blocks you placed or edited by hand stay, and new auto zooms are fitted around them.",
        },
        {
          type: "p",
          text: "New recordings get Auto Zoom automatically. To open recordings without zooms, turn off **Auto zoom new recordings** in **Settings → General**.",
        },
        {
          type: "callout",
          tone: "note",
          title: "Needs cursor data",
          text: "Auto Zoom reads the cursor and keystroke data the Mac app records with screen and window recordings. iPhone and iPad recordings and web recorder takes have no cursor data, so **Auto Zoom** is unavailable for them; add zooms by hand instead.",
        },
        { type: "h2", text: "Add a zoom by hand" },
        {
          type: "table",
          head: ["Zoom menu item", "What it adds"],
          rows: [
            ["**Zoom In**", "A 3-second, 2.0x zoom at the playhead. Drag the target on the preview to aim it."],
            ["**Showcase**", "A gentle 1.35x push-in with a slight 3D skew and the Slow Glide style, easing back to a flat, centered card."],
            ["**Scale Down**", "Shrinks the card to 0.85x for 3 seconds, then back."],
          ],
        },
        {
          type: "p",
          text: "You can also right-click an empty spot on the EFFECTS lane and choose **Add Zoom Region**. Blocks that overlap stack into extra rows on the lane.",
        },
        { type: "h2", text: "Zoom block settings" },
        {
          type: "p",
          text: "Select a zoom block to edit it in the **Zoom** section of the Effects tab.",
        },
        {
          type: "table",
          head: ["Control", "Range", "What it does"],
          rows: [
            ["**Zoom / Scale**", "0.3x to 6.0x", "How far the block pushes in. Below 1.0x the card shrinks instead."],
            ["**Speed**", "Default, Instant, Snappy, Smooth, Slow Glide, Cinematic", "How the zoom moves in and out. **Default** follows the Motion tab speed; **Instant** is a near cut; **Slow Glide** and **Cinematic** ease without bounce."],
            ["**Follow Cursor**", "On or off", "On (the default), the zoomed view drifts with the cursor. Off, it stays on the focus point."],
            ["**Focus**", "Pad", "Where the zoom points."],
            ["**Offset**", "Pad", "Slides the whole card away from its usual position during the block and back after."],
          ],
        },
        {
          type: "p",
          text: "Dragging the focus target on the preview aims the block and turns **Follow Cursor** off for it. Right-click a block for **Zoom Level** presets from 1.5x to 5.0x, **Add Tilt to Block**, **Remove Zoom** and **Delete**.",
        },
        { type: "h2", text: "Project-wide zoom feel" },
        {
          type: "table",
          head: ["Motion tab control", "Range", "Default"],
          rows: [
            ["Speed: **Slow**, **Mellow**, **Quick**, **Rapid**", "1.2 s, 0.8 s, 0.5 s, 0.3 s transitions", "Mellow"],
            ["**Zoom Level**", "1.5x to 4.0x", "2.0x (the starting depth for Auto Zoom)"],
            ["**Follow Speed**", "0% to 100%", "50%: how quickly the zoomed view chases the cursor"],
          ],
        },
        {
          type: "callout",
          tone: "tip",
          text: "For more depth during zooms, turn on **Parallax** or **Motion Blur** in the Effects tab. See [Slide, curtain, tilt and motion effects](/docs/editing/effects).",
        },
      ],
      faqs: [
        {
          question: "How do I add zoom to a screen recording on Mac?",
          answer:
            "Record with the CaptureCat Mac app and it places zooms automatically from your clicks and typing. To add more, open the Zoom menu in the timeline toolbar and choose Zoom In, then drag the target on the preview to aim it.",
        },
        {
          question: "Can I turn off automatic zoom?",
          answer:
            "Yes. Turn off Auto zoom new recordings in Settings → General. You can still run Auto Zoom from the Zoom menu on any recording later.",
        },
        {
          question: "Why is Auto Zoom greyed out?",
          answer:
            "The project has no recorded cursor data. That is the case for iPhone and iPad recordings and for takes from the web recorder. Add zoom blocks by hand with Zoom In.",
        },
      ],
      related: ["editing/effects", "editing/cursor", "editing/timeline"],
      lastModified: CHECKED,
    },
    {
      slug: "editing/cursor",
      title: "Cursor, click effects and click sounds",
      navTitle: "Cursor and clicks",
      description:
        "Restyle the cursor after recording: arrow, hand, dot or ring, size, fluid motion, smoothing, auto-hide, click ripples, and click and keyboard sounds.",
      summary:
        "CaptureCat records your cursor as data rather than burning it into the video, so you restyle it after recording in the Cursor tab. Change its look and size, smooth its motion, add click ripples, and add click and typing sounds that play in the preview and the export.",
      platforms: ["mac", "web"],
      blocks: [
        {
          type: "callout",
          tone: "note",
          text: "These settings apply to screen and window recordings made with the Mac app. The web recorder captures the system cursor as part of the video, and iPhone and iPad recordings have no cursor; use a [tap indicator](/docs/editing/annotations#tap-indicators) to show touches.",
        },
        { type: "h2", text: "Style and size" },
        {
          type: "table",
          head: ["Control", "Options", "Default"],
          rows: [
            ["**Show Cursor**", "On or off", "On"],
            ["**Style**", "macOS Arrow, White Arrow, Hand, Dot, Ring", "macOS Arrow"],
            ["**Size**", "0.5x to 3.0x", "1.5x"],
          ],
        },
        { type: "h2", text: "Motion" },
        {
          type: "p",
          text: "**Fluid Movement** (on by default) lets the drawn cursor follow your path on a spring, so fast moves glide instead of jumping. Clicks always stay exactly where you clicked.",
        },
        {
          type: "table",
          head: ["Control", "Range", "Default", "Effect"],
          rows: [
            ["**Tension**", "20 to 600", "220", "How quickly the cursor accelerates toward where you moved."],
            ["**Friction**", "2 to 80", "24", "Higher settles sooner."],
            ["**Mass**", "0.2x to 6.0x", "1.0x", "Heavier keeps momentum, with more overshoot."],
            ["**Smooth Cursor Motion**", "On or off, **Smoothing** 0.05 to 0.5", "Off, 0.15", "Filters out hand jitter from the recorded path."],
          ],
        },
        { type: "h2", text: "Behavior" },
        {
          type: "list",
          items: [
            "**Auto-Hide Cursor** (off by default) hides the cursor once it has been still for **Hide After** seconds (1 to 10, default 3).",
            "**Loop to Start** glides the cursor back to its first position near the end, for clips that loop.",
            "**Stop at End** freezes the cursor for the final half second.",
          ],
        },
        { type: "h2", text: "Click ripples" },
        {
          type: "p",
          text: "**Show Click Ripple** (on by default) draws a ripple at every recorded click. Set its **Size** (20 to 100, default 40) and **Color** (default white). Click-and-drag selections don't get a ripple.",
        },
        { type: "h2", text: "Click sounds" },
        {
          type: "p",
          text: "Turn on **Click Sound** to play a synthesized tick at every recorded click, in the preview and in the exported file. Choose the **Sound** (Soft Tick, Clicky, Deep or Pop), set **Volume** (10% to 100%, default 70%) and click **Test** to hear it.",
        },
        { type: "h2", text: "Keyboard sounds" },
        {
          type: "p",
          text: "Turn on **Keyboard Sounds** to play typing sounds when you typed during the recording. Sounds: Thock, Clacky, Soft, Cream, Blue Click, Typewriter and Membrane; **Volume** defaults to 60%.",
        },
        {
          type: "callout",
          tone: "note",
          text: "Keyboard sounds need keystroke timing, which the Mac app captures only with **Input Monitoring** allowed in **System Settings → Privacy & Security**. Only when keys were pressed is stored, never what you typed. Recordings made without it can't play typing sounds.",
        },
        { type: "h2", text: "Shortcut overlay" },
        {
          type: "p",
          text: "The **Shortcut Overlay** section shows recorded shortcuts such as ⌘⇧S as an on-screen pill, with **Position**, **Animation** and **Size** controls. See [Show keystrokes](/docs/recording/keystrokes).",
        },
      ],
      faqs: [
        {
          question: "How do I make the cursor bigger in a screen recording?",
          answer:
            "Open the Cursor tab and drag Size, from 0.5x to 3.0x. The default is 1.5x. Because the cursor is recorded as data, this works on recordings you have already made.",
        },
        {
          question: "Can I add click sounds to a screen recording?",
          answer:
            "Yes. Turn on Click Sound in the Cursor tab. A synthesized click plays at each recorded click, in the preview and in the exported video.",
        },
        {
          question: "How do I hide the cursor in a recording?",
          answer:
            "Turn off Show Cursor in the Cursor tab to remove it entirely, or turn on Auto-Hide Cursor to hide it only while it is still.",
        },
      ],
      related: ["editing/auto-zoom", "recording/keystrokes", "editing/audio"],
      lastModified: CHECKED,
    },
    {
      slug: "editing/framing",
      title: "Backgrounds, padding, corners and aspect ratio",
      navTitle: "Framing",
      description:
        "Frame a screen recording: gradient, wallpaper or image backgrounds, padding, rounded corners, shadow, aspect ratios from 16:9 to 9:16, device frames and a logo.",
      summary:
        "The Background tab puts your recording on a styled card: pick a gradient, mesh, color, image or macOS wallpaper, then set padding, corner rounding, shadow and placement. The **Aspect** menu in the header sets the output shape, from 16:9 to vertical 9:16.",
      platforms: ["mac", "web"],
      blocks: [
        { type: "h2", text: "Aspect ratio" },
        {
          type: "p",
          text: "Choose the output shape from the **Aspect** menu in the middle of the header bar. The preview reshapes immediately, and the export uses the same shape. New projects start at 16:9.",
        },
        {
          type: "table",
          head: ["Option", "Suggested for"],
          rows: [
            ["Auto", "Match the recording"],
            ["16:9", "YouTube, X, LinkedIn"],
            ["4:3", "Slides, legacy displays"],
            ["1:1", "Instagram and LinkedIn feed"],
            ["9:16", "TikTok, Shorts, Reels"],
            ["21:9", "Cinematic, ultrawide"],
            ["4:5", "Instagram feed portrait"],
          ],
        },
        { type: "h2", text: "Background" },
        {
          type: "list",
          items: [
            "**Gradient**: **Start Color**, **End Color** and **Angle** (0° to 360°).",
            "**Mesh**: a mesh blend of a **Start Color** and an **End Color**.",
            "**Solid Color**: one **Color**.",
            "**Image**: **Choose Image…** to use your own picture.",
            "**Wallpaper**: the macOS wallpapers plus your own images. Right-click one and choose **Set as Default** to use it for every new recording, or **Remove from Library**.",
            "**Transparent**: no background.",
          ],
        },
        { type: "h3", text: "Look" },
        {
          type: "p",
          text: "The Look section adjusts the background, never your recording: **Blur**, **Pixelate**, **Halftone**, **Grain**, **Brightness**, **Contrast**, **Saturation**, **Hue**, **Tint** with **Tint Amount**, and **Vignette**. **Reset Look** puts them all back.",
        },
        { type: "h2", text: "Frame" },
        {
          type: "table",
          head: ["Control", "Range", "Default"],
          rows: [
            ["**Placement**", "Center, the four edges, the four corners, or drag the card on the pad", "Center (**Reset to Center** undoes a drag)"],
            ["**Padding**", "0 to 300", "48"],
            ["**Shape**", "Rounded Rectangle, Squircle, Rectangle", "Rounded Rectangle"],
            ["**Rounded Corners**", "0 to 20", "8"],
            ["**Shadow**", "0 to 60", "20"],
            ["**Shadow Opacity**", "0% to 100%", "50%"],
          ],
        },
        { type: "h2", text: "iPhone and iPad frames" },
        {
          type: "p",
          text: "For iPhone and iPad recordings, the Frame section adds **iPhone / iPad Frame**, which draws the recording inside a realistic device bezel. It is on by default. See [Record an iPhone or iPad](/docs/recording/iphone-and-ipad).",
        },
        { type: "h2", text: "Menu bar" },
        {
          type: "p",
          text: "Mac recordings get a **Menu Bar** section that cleans up the recorded macOS menu bar:",
        },
        {
          type: "list",
          items: [
            "**Original** leaves it as recorded.",
            "**Hidden** crops the menu bar strip off the recording.",
            "**Dark** and **Light** cover it with a clean bar showing your own **Title** (with **Align**), a fixed **Clock** (default 9:41) and optional **Wi-Fi & Battery Icons**.",
          ],
        },
        {
          type: "p",
          text: "Adjust **Height** (2% to 6% of the video height, default 3.8%) until the real bar is exactly covered.",
        },
        { type: "h2", text: "Logo watermark" },
        {
          type: "p",
          text: "In the **Brand** tab, turn on **Show Watermark** and click **Choose Logo…** (a PNG with transparency works best). Drag it on the position pad, then set **Size** (40 to 400, default 120) and **Opacity** (10% to 100%, default 90%). It starts in the bottom-right corner.",
        },
        {
          type: "callout",
          tone: "tip",
          text: "To tip the card in 3D or slide it in from an edge, see [Slide, curtain, tilt and motion effects](/docs/editing/effects).",
        },
      ],
      faqs: [
        {
          question: "How do I make a vertical 9:16 version of a screen recording?",
          answer:
            "Choose 9:16 in the Aspect menu in the editor's header. The preview and the export both switch to vertical; add zooms so the important part fills the narrower frame.",
        },
        {
          question: "How do I add a background to a screen recording on Mac?",
          answer:
            "Open the Background tab and pick Gradient, Mesh, Solid Color, Image or Wallpaper, then raise Padding to show more of it around your recording.",
        },
      ],
      related: ["editing/effects", "editing/privacy", "export-and-sharing/export"],
      lastModified: CHECKED,
    },
    {
      slug: "editing/effects",
      title: "Slide, curtain, tilt and motion effects",
      navTitle: "Effects",
      description:
        "Add motion effects to a screen recording: 3D tilt, slide-in entrances, a curtain unveil with your logo, background parallax and motion blur.",
      summary:
        "The **Zoom** menu in the timeline toolbar adds every motion effect at the playhead: zooms, 3D **Tilt**, a **Slide** entrance and a **Curtain Unveil**. Their settings, plus **Parallax** and **Motion Blur**, live in the Effects tab.",
      platforms: ["mac", "web"],
      blocks: [
        { type: "h2", text: "Tilt" },
        {
          type: "p",
          text: "**Tilt** (Skew the screen in 3D for a span) adds a block to the EFFECTS lane. The card springs into the skew at the start of the block and back to flat at the end. A tilt can share a block with a zoom: right-click a zoom block and choose **Add Tilt to Block**.",
        },
        {
          type: "list",
          items: [
            "Drag the **Skew** pad: left and right tip a side back, up and down tip the top or bottom back.",
            "One-click presets: **Flat**, **Showcase**, **Lean L**, **Lean R**, **Top Down**.",
            "**Rotation**: -30° to 30°.",
            "**Speed**: the same styles as zoom blocks, from **Instant** to **Cinematic**.",
            "**Cinematic** sets a deep 2.4x push-in with a gentle tilt back in one click.",
          ],
        },
        { type: "h2", text: "Slide" },
        {
          type: "p",
          text: "**Slide** makes the card slide in from an edge with a punchy settle. Choose **Top**, **Bottom**, **Left** or **Right**, then set **Bounce** (default 50%) and **Speed** (1x to 4x; above 1x the slide lands early and holds). **Pull Toward Viewer** adds a 3D pull: the card starts small and deep, then moves to the front as it lands.",
        },
        {
          type: "p",
          text: "Drag the Slide block on the EFFECTS lane to place it and drag its edge to set its length. At 0:00 it plays as an intro; anywhere else the card slides away and back.",
        },
        { type: "h2", text: "Curtain Unveil" },
        {
          type: "p",
          text: "A curtain covers the screen and peels away from a corner like a page turn. Choose the corner (**Top Left**, **Top Right**, **Bottom Left**, **Bottom Right**), the **Length** (0.4 to 3.0 seconds, default 1.6) and the **Curtain** color (**Reset Color** returns to charcoal).",
        },
        {
          type: "p",
          text: "Click **Choose Logo…** to put your logo on the curtain; it peels away with it. Set **Logo Opacity**, **Logo Size** (5% to 80% of the card width, default 25%) and optionally **Tint Logo** with one color.",
        },
        { type: "h2", text: "Parallax and Motion Blur" },
        {
          type: "table",
          head: ["Effect", "Control", "What it does"],
          rows: [
            ["**Parallax**", "**Strength** 5% to 100% (40% when turned on)", "The background drifts gently with zooms for a sense of depth."],
            ["**Motion Blur**", "**Strength** 0% to 100% (default 50%)", "Subtle blur during fast camera movement."],
          ],
        },
        { type: "h2", text: "Camera layouts" },
        {
          type: "p",
          text: "When the recording includes your webcam, the Zoom menu also offers **Camera: Full Screen**, **Camera: Side by Side** and **Camera: Hide**, which change the layout for a span of the video. See [Camera](/docs/recording/camera).",
        },
        {
          type: "callout",
          tone: "tip",
          text: "Deleting the Slide or Curtain Unveil block turns that effect off; ⌘Z brings it back with its settings.",
        },
      ],
      related: ["editing/auto-zoom", "editing/framing", "editing/timeline"],
      lastModified: CHECKED,
    },
    {
      slug: "editing/annotations",
      title: "Text, arrows, shapes and drawings",
      navTitle: "Annotations",
      seoTitle: "Add Text, Arrows and Shapes to a Screen Recording | CaptureCat Docs",
      description:
        "Add text labels, arrows, callouts, rectangles, ellipses, freehand drawings and tap indicators to a screen recording, with Build In and Build Out effects.",
      summary:
        "Click **Add Annotation** in the timeline toolbar to drop a text label, arrow, callout, drawing, rectangle, ellipse or tap indicator at the playhead. Each one is a block on the ANNOTATE lane that you style in the Annotate tab and animate with Keynote-style **Build In** and **Build Out** effects.",
      platforms: ["mac", "web"],
      blocks: [
        { type: "h2", text: "Annotation types" },
        {
          type: "table",
          head: ["Type", "What it is", "Starting length"],
          rows: [
            ["**Text Label**", "A text overlay, with an optional background pill", "3 seconds"],
            ["**Arrow**", "A directional arrow", "3 seconds"],
            ["**Callout**", "A line with a labelled box", "3 seconds"],
            ["**Drawing**", "Freehand brush strokes", "10 seconds"],
            ["**Rectangle**", "A box with optional fill", "3 seconds"],
            ["**Ellipse**", "A circle or oval with optional fill", "3 seconds"],
            ["**Tap Indicator**", "A looping touch ripple for iPhone and iPad recordings", "3 seconds"],
          ],
        },
        { type: "h2", text: "Add an annotation" },
        {
          type: "steps",
          steps: [
            {
              title: "Move the playhead",
              text: "Scrub to where the annotation should appear.",
            },
            {
              title: "Pick a type",
              text: "Click **Add Annotation** (the pen button) in the timeline toolbar and choose a type. Or right-click an empty spot on the ANNOTATE lane and choose **Add Text Label**, **Add Arrow** and so on.",
            },
            {
              title: "Place it on the preview",
              text: "Drag it into position. Text labels and callouts open ready to type; double-click a label on the preview to edit it again later.",
            },
            {
              title: "Set its timing",
              text: "Drag the block's edges on the ANNOTATE lane, type **Start** and **End** times in the Annotate tab, or click **At Playhead** to move it to the playhead.",
            },
          ],
        },
        { type: "h2", text: "Style it" },
        {
          type: "p",
          text: "Select an annotation and its settings appear in the Annotate tab. A floating bar above the selected annotation also offers its font, weight, color, background and size.",
        },
        {
          type: "table",
          head: ["Section", "Controls"],
          rows: [
            ["Text", "**Size** (10 to 72), **Font**, weight from Regular to Heavy, **Uppercase**"],
            ["Style", "**Color**, **Background** or **Fill** (on or off, with its own color), **Corners** (0 to 24), **Border** (0 to 12)"],
            ["Effects", "**Opacity** (20% to 100%), **Blackout**, **Build In**, **Build Out**, **Shadow**"],
          ],
        },
        { type: "h2", text: "Build In and Build Out" },
        {
          type: "p",
          text: "Choose how an annotation enters and leaves: **None**, **Fade**, **Pop**, **Scale**, **Slide Up**, **Drop**, **Explode** or **Draw On**. Builds take 0.3 seconds. **Draw On** reveals a drawing stroke by stroke over 1 second, as if drawn live (as Build Out it un-draws); on other types it fades.",
        },
        { type: "h2", text: "Spotlight with Blackout" },
        {
          type: "p",
          text: "**Blackout** (Off to 90%) darkens everything around the annotation. A rectangle or ellipse cuts its own shape out of the dark area, so it works as a spotlight on one part of the screen.",
        },
        { type: "h2", text: "Drawings" },
        {
          type: "p",
          text: "With a drawing selected, draw directly on the preview. **Undo Last** removes the latest stroke and **Clear** removes them all.",
        },
        { type: "h2", text: "Tap indicators" },
        {
          type: "p",
          text: "iPhone and iPad recordings carry no touch data, so you place taps by hand. Add a **Tap Indicator**, drag the ripple over the tapped spot, and set its **Size** (20 to 120). It pulses for the whole length of its block.",
        },
      ],
      faqs: [
        {
          question: "How do I add an arrow to a screen recording?",
          answer:
            "In the CaptureCat editor, click Add Annotation in the timeline toolbar and choose Arrow. Drag its ends on the preview, then drag the block on the ANNOTATE lane to set when it shows.",
        },
        {
          question: "How do I show taps on an iPhone screen recording?",
          answer:
            "Add a Tap Indicator from the Add Annotation menu, drag it over the spot that was tapped, and size the block on the timeline to the length of the tap.",
        },
        {
          question: "Can annotations animate in and out?",
          answer:
            "Yes. Pick a Build In and Build Out effect in the Annotate tab, such as Fade, Pop or Slide Up. Drawings can also use Draw On to appear stroke by stroke.",
        },
      ],
      related: ["editing/privacy", "editing/timeline", "recording/iphone-and-ipad"],
      lastModified: CHECKED,
    },
    {
      slug: "editing/captions",
      title: "Captions and subtitles",
      navTitle: "Captions",
      seoTitle: "Add Captions to a Screen Recording on Mac | CaptureCat Docs",
      description:
        "Add captions to a screen recording on Mac. CaptureCat transcribes speech on your device with Whisper, then you edit the text and style the subtitles.",
      summary:
        "Click **Generate Subtitles** in the Subtitles tab and CaptureCat transcribes the recording's speech on your own device with OpenAI's Whisper model. Edit any line, pick a preset or style the captions yourself; they are burned into every export while **Show Subtitles** is on.",
      platforms: ["mac", "web"],
      blocks: [
        {
          type: "steps",
          steps: [
            {
              title: "Open the Subtitles tab",
              text: "Make sure **Show Subtitles** is on (it is by default).",
            },
            {
              title: "Generate",
              text: "Click **Generate Subtitles**. The first time, the speech model downloads automatically: about 150 MB on the Mac, and about 210 MB in the web editor (80 MB on browsers without WebGPU).",
            },
            {
              title: "Wait for the transcript",
              text: "Progress shows under the button. When it finishes, the captions appear on the preview and the count shows, for example **42 subtitles**.",
            },
            {
              title: "Fix the text",
              text: "Under **Edit Subtitles**, each caption shows its time range and an editable text field. Changes show on the preview as you type.",
            },
          ],
        },
        { type: "h2", text: "What gets transcribed" },
        {
          type: "list",
          items: [
            "**English speech.** The model is Whisper base.en, which transcribes English only, on the Mac and the web.",
            "**Your microphone.** When a recording has both system audio and a microphone track, the microphone track is transcribed.",
            "**Not voice-overs.** Voice-over clips recorded in the editor aren't included.",
            "**Short lines.** Each caption holds up to 8 words or 3 seconds and breaks after a sentence ends.",
          ],
        },
        { type: "h2", text: "On-device transcription" },
        {
          type: "p",
          text: "On the Mac, transcription runs locally with WhisperKit. In the web editor, it runs inside your browser. Either way the recording's audio is not uploaded to transcribe it; only the model itself is downloaded, once.",
        },
        { type: "h2", text: "Style the captions" },
        {
          type: "p",
          text: "**Presets** set the whole look in one click: **Clean**, **Boxed**, **Neon**, **Karaoke**, **Shout** and **Minimal**. Then fine-tune:",
        },
        {
          type: "table",
          head: ["Section", "Controls"],
          rows: [
            ["Text", "**Size** (16 to 64, default 32), **Font**, weight from Regular to Heavy (default Bold), **Uppercase**, **Color**"],
            ["Style", "Position **Top**, **Center** or **Bottom** (or drag on the pad); **Outline**, **Background**, **Glow** or **Plain**; **Background** color; **Karaoke Highlight** with a **Highlight** color"],
          ],
        },
        {
          type: "p",
          text: "**Karaoke Highlight** colors the words of each caption as they are spoken.",
        },
        { type: "h2", text: "Regenerate or remove" },
        {
          type: "p",
          text: "**Regenerate** transcribes again and replaces the current captions, including your text edits. **Delete** removes all captions from the project.",
        },
        { type: "h2", text: "Burned in or not" },
        {
          type: "p",
          text: "Captions are drawn into the video: while **Show Subtitles** is on they appear in the preview and in every export. Turn it off to export without them; the captions stay in the project for later.",
        },
      ],
      faqs: [
        {
          question: "Does CaptureCat transcribe on device?",
          answer:
            "Yes. The Mac app transcribes with Whisper running locally, and the web editor runs the same model in your browser. The audio is not sent to a server for transcription.",
        },
        {
          question: "Which languages can CaptureCat caption?",
          answer: "English. Both the Mac app and the web editor use Whisper's English-only base.en model.",
        },
        {
          question: "Can I turn captions off for one export?",
          answer:
            "Yes. Turn off Show Subtitles in the Subtitles tab before exporting. The captions stay in the project, and turning the switch back on restores them.",
        },
      ],
      related: ["editing/annotations", "editing/audio", "export-and-sharing/export"],
      lastModified: CHECKED,
    },
    {
      slug: "editing/privacy",
      title: "Blur, pixelate and spotlight parts of a recording",
      navTitle: "Blur and privacy",
      seoTitle: "Blur Part of a Screen Recording on Mac | CaptureCat Docs",
      description:
        "Blur or pixelate sensitive areas of a screen recording, dim everything but one region, keep one area sharp, and hide the macOS menu bar.",
      summary:
        "Open the **Focus & Blur** menu in the timeline toolbar, choose **Add Blur** or **Add Pixelate**, and drag over the area to hide. Each region is a block on the FOCUS lane with its own strength and timing, applied the same way in the preview and the export.",
      platforms: ["mac", "web"],
      blocks: [
        { type: "h2", text: "Blur or pixelate an area" },
        {
          type: "steps",
          steps: [
            {
              title: "Move the playhead",
              text: "Scrub to where the sensitive content first appears.",
            },
            {
              title: "Choose Add Blur or Add Pixelate",
              text: "Click the **Focus & Blur** button (the target icon) in the timeline toolbar and choose **Add Blur** or **Add Pixelate**.",
            },
            {
              title: "Drag over the area",
              text: "Drag a rectangle on the preview over what you want hidden. A 3-second block appears on the FOCUS lane.",
            },
            {
              title: "Cover the right span",
              text: "Drag the block's edges on the FOCUS lane so it covers the whole time the content is visible. Move or resize the region on the preview at any time.",
            },
          ],
        },
        { type: "h2", text: "Blur settings" },
        {
          type: "table",
          head: ["Control", "Range", "What it does"],
          rows: [
            ["**Blur** / **Pixelate**", "Choice", "Blur softens the region with a feathered edge; Pixelate covers it with a mosaic."],
            ["**Strength**", "10% to 100% (default 60%)", "How strong the blur or how coarse the mosaic is."],
            ["**Animated**", "Pixelate only", "Jitters the mosaic over time, the classic censor look."],
          ],
        },
        {
          type: "callout",
          tone: "warning",
          title: "Regions don't track movement",
          text: "A region stays exactly where you drew it for the length of its block. If the sensitive content moves or scrolls, split the job into several blocks, each covering one position. Scrub through the whole span before you export.",
        },
        {
          type: "p",
          text: "Blocks on the FOCUS lane can't overlap in time, so one blur, pixelate, highlight or depth focus region is active at once. A new region goes into the next free gap on the lane.",
        },
        { type: "h2", text: "Highlight a region" },
        {
          type: "p",
          text: "**Add Highlight** softly dims everything outside a rectangle so attention stays on it. Set the dimming with **Opacity** (10% to 90%, default 55%) in the **Highlight Mask** section of the Effects tab.",
        },
        { type: "h2", text: "Depth Focus" },
        {
          type: "p",
          text: "**Add Depth Focus** keeps a region sharp and blurs the rest with a graduated, camera-like blur. Choose **Area** (sharp inside the rectangle) or **Tilt Shift** (a sharp band through it), then set **Blur Strength** (default 70%), **Focus Falloff**, and **Corner Radius** for Area or **Angle** (-90° to 90°) for Tilt Shift.",
        },
        { type: "h2", text: "Other ways to keep things private" },
        {
          type: "list",
          items: [
            "**Hide the menu bar.** In the Background tab, **Menu Bar → Hidden** crops the macOS menu bar off, and **Dark** or **Light** replaces it with a clean bar and a fixed clock. See [Framing](/docs/editing/framing#menu-bar).",
            "**Black out around an annotation.** An annotation's **Blackout** setting darkens everything but a rectangle or ellipse. See [Annotations](/docs/editing/annotations#spotlight-with-blackout).",
            "**Keystrokes.** Typing sounds use only when keys were pressed, never what you typed.",
          ],
        },
      ],
      faqs: [
        {
          question: "How do I blur part of a screen recording on Mac?",
          answer:
            "In the CaptureCat editor, open Focus & Blur in the timeline toolbar, choose Add Blur, and drag over the area on the preview. Then stretch the block on the FOCUS lane to cover the time the content is visible.",
        },
        {
          question: "Can CaptureCat blur something that moves?",
          answer:
            "Not automatically. A blur region stays where you draw it. Cover moving content with several blur blocks in a row, each placed where the content is during its span.",
        },
        {
          question: "What is the difference between blur and pixelate?",
          answer:
            "Blur softens the area with a smooth, feathered blur. Pixelate replaces it with a mosaic of blocks, which can also be animated to jitter over time.",
        },
      ],
      related: ["editing/annotations", "editing/framing", "editing/timeline"],
      lastModified: CHECKED,
    },
    {
      slug: "editing/timeline",
      title: "Trim, split, cut and speed up",
      navTitle: "Timeline",
      seoTitle: "Trim, Cut and Speed Up Screen Recordings | CaptureCat Docs",
      description:
        "Edit on the CaptureCat timeline: trim the ends, split with Command B, slice and remove sections, speed up or slow down clips, and undo any change.",
      summary:
        "Drag the ends of the VIDEO lane to trim, press ⌘B to split at the playhead, and right-click a clip to set its speed from 0.5x to 4x. Blocks on every lane can be dragged, resized and deleted, and each timeline change can be undone.",
      platforms: ["mac", "web"],
      blocks: [
        { type: "h2", text: "Lanes" },
        {
          type: "table",
          head: ["Lane", "What goes there"],
          rows: [
            ["VIDEO", "The recording, its trim, splits and speed changes. The speaker button on the block mutes the recorded audio."],
            ["VOICE", "Voice-over clips. See [Audio](/docs/editing/audio)."],
            ["EFFECTS", "Zoom, tilt, Slide and Curtain Unveil blocks. Overlapping blocks stack into extra rows."],
            ["FOCUS", "Blur, pixelate, highlight, depth focus and camera layout blocks. These don't overlap."],
            ["ANNOTATE", "Text, arrows, callouts, shapes, drawings and tap indicators."],
          ],
        },
        { type: "h2", text: "Trim the start and end" },
        {
          type: "p",
          text: "Drag the left or right edge of the VIDEO block inward. While the video is a single clip, dragging the middle of the block slides the trimmed window through the recording instead. Trimmed footage is hidden, not deleted: drag the edge back out to restore it.",
        },
        { type: "h2", text: "Split a clip" },
        {
          type: "list",
          items: [
            "**At the playhead:** press ⌘B, or click **Split at Playhead** in the toolbar.",
            "**Anywhere:** press B (or click the scissors) to arm the slice tool, then click the VIDEO lane where you want to cut. Press B again to put it away.",
            "**Undo a split:** right-click the clip just after it and choose **Remove Split at Start**.",
          ],
        },
        { type: "h2", text: "Remove a section" },
        {
          type: "steps",
          steps: [
            { title: "Split around it", text: "Split at the start and the end of the part you don't want." },
            { title: "Select the clip", text: "Click the clip between the two splits." },
            { title: "Delete it", text: "Press Delete. The clip is lifted out of the VIDEO lane." },
          ],
        },
        {
          type: "callout",
          tone: "note",
          title: "Removing a clip leaves a gap",
          text: "The removed span shows only the background and is silent; the video does not get shorter. To shorten the video, trim its ends or speed a section up. You can't remove the last remaining clip.",
        },
        { type: "h2", text: "Speed up or slow down" },
        {
          type: "p",
          text: "Right-click a clip on the VIDEO lane and choose **Set Speed**, then a speed from 0.5x to 4x. Speed applies to the whole clip under the pointer, so split first to change just one part. Right-click a sped-up clip for **Change Speed** or **Remove Speed**.",
        },
        { type: "h2", text: "Work with blocks" },
        {
          type: "list",
          items: [
            "Drag a block to move it; drag either edge to change when it starts or ends. Edges snap to nearby edges, with a guide line.",
            "Press ⌘D to duplicate the selected zoom, tilt, blur, highlight or speed block.",
            "Press Delete, or right-click and choose **Delete**, to remove the selected block.",
            "Right-click an empty spot on a lane to add a block there, for example **Add Zoom Region** or **Add Blur**.",
          ],
        },
        { type: "h2", text: "Undo and redo" },
        {
          type: "p",
          text: "Use ⌘Z and ⇧⌘Z, or the undo and redo buttons in the timeline toolbar. For saved versions of a project you can go back to later, see [Versions](/docs/export-and-sharing/versions).",
        },
        { type: "h2", text: "Shortcuts" },
        {
          type: "shortcuts",
          rows: [
            ["Space", "Play or pause"],
            ["← / →", "Step one frame (1/30 second)"],
            ["⇧← / ⇧→", "Step one second"],
            ["Home / End", "Go to start or end"],
            ["⌘B", "Split at playhead"],
            ["B", "Slice tool on or off"],
            ["⌘D", "Duplicate the selected block"],
            ["Delete", "Delete the selected block or clip"],
            ["⌘Z / ⇧⌘Z", "Undo / redo"],
            ["⌥⌘I", "Show or hide the inspector"],
          ],
        },
        {
          type: "p",
          text: "Zoom the timeline with a trackpad pinch or the **Zoom In Timeline**, **Zoom Out Timeline** and **Fit Timeline** buttons. For every shortcut in the app, see [Keyboard shortcuts](/docs/getting-started/keyboard-shortcuts).",
        },
      ],
      faqs: [
        {
          question: "How do I cut out the middle of a screen recording?",
          answer:
            "Split at the start and end of the part you don't want (⌘B at the playhead), select the clip between the splits and press Delete. The span then shows only the background; trim or speed up to shorten the video.",
        },
        {
          question: "How do I speed up part of a screen recording?",
          answer:
            "Split around the part, right-click that clip on the VIDEO lane, choose Set Speed and pick a speed up to 4x. The preview and export both play it at that speed.",
        },
      ],
      related: ["editing", "editing/audio", "getting-started/keyboard-shortcuts"],
      lastModified: CHECKED,
    },
    {
      slug: "editing/audio",
      title: "Audio levels and voice over",
      navTitle: "Audio and voice over",
      seoTitle: "Add a Voice Over to a Screen Recording on Mac | CaptureCat Docs",
      description:
        "Balance system audio, microphone and voice over in CaptureCat, mute the recorded audio, and record a voice over onto the timeline while the video plays.",
      summary:
        "The Audio tab has three faders: **System Audio**, **Microphone** and **Voice Over**. To add narration, click **Record Voice Over** in the timeline toolbar and talk while the video plays; the take lands on the VOICE lane where you can move and trim it.",
      platforms: ["mac", "web"],
      blocks: [
        { type: "h2", text: "Faders" },
        {
          type: "table",
          head: ["Fader", "Range", "Controls"],
          rows: [
            ["**System Audio**", "0% to 100%", "Sound from your Mac that was recorded with the video."],
            ["**Microphone**", "0% to 100%", "Your recorded microphone."],
            ["**Voice Over**", "0% to 150%", "All voice-over clips recorded in the editor."],
          ],
        },
        {
          type: "p",
          text: "All three start at 100%, and drag to 0% to silence a source. The speaker button on the VIDEO block mutes the recorded system audio and microphone together; voice-overs keep playing.",
        },
        { type: "h2", text: "Record a voice over" },
        {
          type: "steps",
          steps: [
            {
              title: "Move the playhead",
              text: "Scrub to where the narration should start.",
            },
            {
              title: "Start recording",
              text: "Click **Record Voice Over** (the microphone button) in the timeline toolbar. Allow microphone access the first time. The video starts playing so you can talk over it.",
            },
            {
              title: "Stop",
              text: "Click the button again (**Stop Recording**). The take is added to the VOICE lane, starting where you began.",
            },
          ],
        },
        { type: "h2", text: "Edit voice-over clips" },
        {
          type: "list",
          items: [
            "Drag a clip to move it in time.",
            "Drag either edge to trim it.",
            "Right-click and choose **Delete Voice Over**, or select it and press Delete.",
            "Record as many takes as you like; set their overall level with the **Voice Over** fader.",
          ],
        },
        { type: "h2", text: "Click and typing sounds" },
        {
          type: "p",
          text: "Synthesized click and keyboard sounds are set in the Cursor tab, with their own volume. See [Cursor, click effects and click sounds](/docs/editing/cursor#click-sounds).",
        },
        { type: "h2", text: "Background noise" },
        {
          type: "p",
          text: "The editor has no noise-reduction filter. For a cleaner microphone, turn on macOS Voice Isolation before you record: the recording panel's **Voice Isolation & Mic Modes…** menu item opens the system picker. See [Record audio](/docs/recording/audio).",
        },
        {
          type: "callout",
          tone: "note",
          text: "Spans where you removed a clip from the VIDEO lane are silent, matching the blank video. Speed changes apply to the recorded audio as well as the picture.",
        },
      ],
      faqs: [
        {
          question: "Can I add a voice over to a screen recording on Mac?",
          answer:
            "Yes. In the CaptureCat editor, put the playhead where the narration starts, click Record Voice Over and talk while the video plays. Click again to stop; the clip appears on the VOICE lane.",
        },
        {
          question: "How do I mute the original audio of a recording?",
          answer:
            "Click the speaker button on the VIDEO block in the timeline, or drag System Audio and Microphone to 0% in the Audio tab. Voice-over clips are not affected.",
        },
      ],
      related: ["recording/audio", "editing/captions", "editing/timeline"],
      lastModified: CHECKED,
    },
  ],
};
