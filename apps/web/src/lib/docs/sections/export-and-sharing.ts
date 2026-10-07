import type { DocSection } from "../types";

/**
 * Checked against apps/macos/CaptureCat: ExportSheetController.swift,
 * Models/ExportSettings.swift, Services/ExportFormats.swift (GIFExportPolicy,
 * static-span collapse), Services/VideoExporter.swift, ShareJobCenter.swift,
 * ShareIntelligence.swift, SettingsWindowController.swift (Sync exports to
 * cloud) and ProjectBrowserViewController.swift (card menu, upload states);
 * apps/web: editor/ui/export/ExportDialog.tsx + SharePanel.tsx,
 * editor/state/shareCenter.ts, editor/engine/export/exporter.ts,
 * components/dashboard/{share-settings-dialog,video-details,video-card,
 * video-library,video-analytics,profile-card}.tsx, components/share/*,
 * routes/{share.$videoId,embed.$videoId,$username}.tsx, routes/api/oembed.ts,
 * public/embed.js, server.ts; apps/api: routes/{video,upload,hub,analytics,
 * profile,playlists}.ts, lib/upload-policy.ts, lib/plans.ts and the plan rows
 * in migrations 0008, 0016, 0023, 0025 and 0029.
 */
const CHECKED = "2026-10-07";

const SCRIPT_EMBED = `<script async src="https://capturecat.so/embed.js" data-capturecat-id="VIDEO_ID"></script>`;

const IFRAME_EMBED = `<iframe src="https://capturecat.so/embed/VIDEO_ID" width="800" height="450" frameborder="0" allow="fullscreen" allowfullscreen style="aspect-ratio:16/9;width:100%;height:auto"></iframe>`;

const PLAN_PAUSE_TEXT =
  "Share links are part of Pro. If your plan ends, every link shows viewers that the share is paused because the owner's plan no longer includes cloud sharing. The files are kept, and resubscribing brings every link back.";

export const EXPORT_AND_SHARING: DocSection = {
  id: "export-and-sharing",
  title: "Export and sharing",
  description: "Export files, share links, share controls, comments and analytics.",
  pages: [
    // ── Export ────────────────────────────────────────────────────────────
    {
      slug: "export-and-sharing/export",
      title: "Export a screen recording to MP4 or MOV",
      navTitle: "Export to MP4 or MOV",
      description:
        "Export CaptureCat recordings to MP4 or MOV at 720p, 1080p, 4K or a custom size, 30 or 60 fps, with a live bitrate estimate. Free, with no watermark.",
      summary:
        "Click **Export…** in the editor, choose a format, resolution, frame rate and quality, and CaptureCat renders the file on your own device. Exporting is free on every plan and adds no watermark.",
      platforms: ["mac", "web"],
      blocks: [
        { type: "h2", text: "Export a video" },
        {
          type: "steps",
          steps: [
            {
              title: "Open the export sheet",
              text: "In the editor, click **Export…** in the top bar. The **Export Video** sheet opens with the settings you used last time for this project.",
            },
            {
              title: "Choose the settings",
              text: "Pick a **Format**, **Resolution**, **Frame Rate** and **Quality**. The line under the quality slider shows what you will get, for example `High • 1920x1080 @ 60 fps • ~23.2 Mbps`.",
            },
            {
              title: "Click Export and choose where to save",
              text: "On the Mac a save panel opens, the sheet shows **Exporting…** with a percentage, and the finished file is revealed in Finder. In the web editor the browser's save picker opens when it has one; otherwise the file downloads when it is ready.",
            },
          ],
        },
        { type: "h2", text: "Export settings" },
        {
          type: "table",
          head: ["Setting", "Options", "What it does"],
          rows: [
            ["**Format**", "MP4, MOV, GIF", "MP4 and MOV contain the same video. GIF has its own rules: see [Export a GIF](/docs/export-and-sharing/gif)."],
            ["**Resolution**", "720p, 1080p, 4K, Custom", "Sets the width: 1280, 1920 or 3840 pixels. The height follows the project's aspect ratio, so the file has exactly the shape the editor shows."],
            ["**Size**", "Width × Height", "Appears when Resolution is **Custom**. The exact pixel size; an odd number is rounded up to the next even one."],
            ["**Frame Rate**", "30 fps, 60 fps", "60 fps keeps cursor movement and zooms smooth; 30 fps halves the bitrate."],
            ["**Quality**", "50% to 100%, in 5% steps", "Named **Draft**, **Good**, **High** or **Master** in the caption. Higher quality means a higher bitrate and a larger file."],
            ["**Fast export (collapse still frames)**", "On or off", "Writes stretches where nothing changes as one long frame. See below."],
          ],
        },
        {
          type: "p",
          text: "A new project starts at MP4, 1080p, 60 fps, 85% quality (High), with fast export on. CaptureCat saves your choices with the project when you export.",
        },
        { type: "h2", text: "Quality and bitrate" },
        {
          type: "p",
          text: "The caption under the slider is a live estimate of the average video bitrate. It scales with the number of pixels per frame, the frame rate and the quality, and never drops below 3 Mbps. At 85% quality and 16:9:",
        },
        {
          type: "table",
          head: ["Resolution", "Frame rate", "Estimated bitrate"],
          rows: [
            ["1080p (1920x1080)", "30 fps", "~11.6 Mbps"],
            ["1080p (1920x1080)", "60 fps", "~23.2 Mbps"],
            ["4K (3840x2160)", "60 fps", "~92.6 Mbps"],
          ],
        },
        {
          type: "p",
          text: "For a rough file size, multiply the bitrate by the length in seconds and divide by 8: about 870 MB for five minutes at 23.2 Mbps. Treat it as a ceiling rather than a promise.",
        },
        { type: "h2", text: "Fast export" },
        {
          type: "p",
          text: "Screen recordings are mostly still. With **Fast export (collapse still frames)** on, a stretch where nothing on screen changes is written as one long frame instead of 30 or 60 identical ones per second. Every moment of the video looks exactly the same as a normal export, and exports of mostly still recordings finish much faster. The file has a variable frame rate as a result.",
        },
        {
          type: "p",
          text: "If another video editor handles variable-frame-rate files badly, turn fast export off to get classic constant-frame-rate output.",
        },
        { type: "h2", text: "Codec and colour" },
        {
          type: "list",
          items: [
            "**On the Mac**, MP4 and MOV are encoded as HEVC (H.265), using the Mac's hardware video encoder where it has one.",
            "**In the web editor**, the video is HEVC when your browser can encode it, otherwise H.264.",
            "**Colour** is tagged to match the recording, so a Display P3 recording stays P3 and an sRGB one stays sRGB.",
            "**Preview equals export.** The editor preview and the exporter use the same layout and effect maths, so the file matches what you saw.",
          ],
        },
        { type: "h2", text: "Export a still as PNG" },
        {
          type: "p",
          text: "For a still capture in Image treatment, the sheet adds a **Type** row with **Image (PNG)** and **Video (MP4)**. It starts on PNG, unless the still has timed effects such as a zoom, in which case it starts on video. For PNG the sheet is titled **Export Image**, the Format, Frame Rate and Quality rows hide, and Resolution still sets the image size.",
        },
        { type: "h2", text: "Share while you export" },
        {
          type: "p",
          text: "If you are signed in on a plan with share links, the sheet also shows **Share link after export**. Turn it on and the file uploads as a share link after it is saved. See [Share a screen recording with a link](/docs/export-and-sharing/share-links). GIF and PNG exports cannot become share links.",
        },
        { type: "h2", text: "Differences in the web editor" },
        {
          type: "list",
          items: [
            "**Cancel** stays active while exporting and stops the render. On the Mac, Cancel is disabled until the export finishes.",
            "The file goes where the browser's save picker points, or to your downloads folder when the browser has no picker.",
          ],
        },
        {
          type: "callout",
          tone: "tip",
          text: "Exporting files is free on every plan, with every effect, up to 4K at 60 fps and with no CaptureCat watermark. The paid part is hosting: share links, comments and analytics. See [Plans](/docs/account/plans).",
        },
      ],
      faqs: [
        {
          question: "How do I export a screen recording as MP4 on a Mac?",
          answer:
            "Open the recording in CaptureCat, click **Export…**, set Format to MP4, pick a resolution and frame rate, then click **Export** and choose where to save. The file is revealed in Finder when it is done.",
        },
        {
          question: "Does CaptureCat add a watermark to exported videos?",
          answer:
            "No. Exports carry no CaptureCat watermark on any plan. The only watermark is the optional brand logo you add yourself in the editor.",
        },
        {
          question: "Should I export MP4 or MOV?",
          answer:
            "Both hold the same video. MP4 plays almost everywhere and is what the one-click **Share…** uses. Choose MOV if your workflow expects QuickTime files.",
        },
        {
          question: "Why does my exported video have a variable frame rate?",
          answer:
            "**Fast export (collapse still frames)** is on. It writes still stretches as single long frames, which looks identical but makes the file variable-frame-rate. Turn it off in the export sheet for constant frame rate.",
        },
      ],
      related: ["export-and-sharing/gif", "export-and-sharing/share-links", "editing/framing", "account/plans"],
      lastModified: CHECKED,
    },

    // ── GIF ───────────────────────────────────────────────────────────────
    {
      slug: "export-and-sharing/gif",
      title: "Export a screen recording as an animated GIF",
      navTitle: "Export a GIF",
      description:
        "Turn a CaptureCat recording into a looping animated GIF on the Mac or the web: 20 fps, up to 960 pixels on the long edge, from the normal export sheet.",
      summary:
        "Choose **GIF** as the format in the export sheet. CaptureCat renders every frame through the same compositor as a video export and writes a GIF that loops forever, at up to 20 fps and 960 pixels on its longest side.",
      platforms: ["mac", "web"],
      blocks: [
        {
          type: "steps",
          steps: [
            {
              title: "Open the export sheet",
              text: "In the editor, click **Export…**.",
            },
            {
              title: "Set Format to GIF",
              text: "The caption changes to the GIF you will get, for example `GIF • 960x540 @ 20 fps • loops`, and the share toggles disappear.",
            },
            {
              title: "Pick a resolution",
              text: "**Resolution** sets the shape and the starting size before the GIF is scaled down. Use **Custom** for a GIF smaller than 960 pixels.",
            },
            {
              title: "Click Export",
              text: "Choose where to save, as with a video.",
            },
          ],
        },
        { type: "h2", text: "How GIF export works" },
        {
          type: "table",
          head: ["", "What you get"],
          rows: [
            ["**Frame rate**", "20 fps, whether the sheet says 30 or 60 fps. GIF frame times are whole hundredths of a second and browsers slow down very short ones, so 20 fps (5 hundredths per frame) is the fastest rate that keeps exact time."],
            ["**Size**", "Scaled down evenly until the long edge is at most 960 pixels. 720p, 1080p and 4K at 16:9 all give 960x540. A Custom size that is already smaller is kept."],
            ["**Looping**", "Loops forever."],
            ["**Frames**", "Every frame is rendered; fast export does not apply to GIFs."],
            ["**Colour**", "Converted to sRGB, since GIF has no colour profile. The palette comes from each platform's encoder (ImageIO on the Mac, a median-cut encoder on the web), the one thing that can differ between them."],
          ],
        },
        { type: "h2", text: "Keep GIFs small" },
        {
          type: "list",
          items: [
            "Trim to the moment you want to show. See [Timeline](/docs/editing/timeline).",
            "Use a tighter aspect ratio or crop so the important part fills the frame. See [Framing](/docs/editing/framing).",
            "Choose **Custom** with a smaller size, such as 640x360, for chat and docs.",
            "For anything longer than a few seconds, an MP4 is far smaller and sharper.",
          ],
        },
        {
          type: "callout",
          tone: "note",
          text: "A GIF cannot become a share link, because share links carry video only (MP4, MOV or WebM). **Sync exports to cloud** skips GIFs as well. To share the clip with a link, export it as MP4.",
        },
      ],
      faqs: [
        {
          question: "Can CaptureCat make a GIF from a screen recording?",
          answer:
            "Yes. In the export sheet set Format to **GIF**. You get a looping GIF of the edited recording, with zooms, cursor effects and annotations, at up to 20 fps and 960 pixels wide.",
        },
        {
          question: "Why is my GIF 20 fps when I chose 60 fps?",
          answer:
            "GIF timing works in hundredths of a second, and 20 fps is the fastest rate browsers play at exactly the right speed. Both 30 and 60 fps settings export a 20 fps GIF.",
        },
        {
          question: "Can I share a GIF as a CaptureCat link?",
          answer:
            "No. Share links are for video. Export an MP4 and share that instead; the share page plays it inline and can be embedded.",
        },
      ],
      related: ["export-and-sharing/export", "editing/timeline", "editing/framing"],
      lastModified: CHECKED,
    },

    // ── Share links ───────────────────────────────────────────────────────
    {
      slug: "export-and-sharing/share-links",
      title: "Share a screen recording with a link",
      navTitle: "Share links",
      description:
        "Upload a CaptureCat recording and get a share link with a watch page, transcript, comments and analytics, from the Mac app or the web editor.",
      summary:
        "Turn on **Share link after export** in the export sheet, or choose **Share…** on a project, and CaptureCat uploads the video in the background and gives you a `capturecat.so/share/…` link. Viewers watch in any browser without an account.",
      platforms: ["mac", "web"],
      plan: "pro",
      blocks: [
        { type: "h2", text: "Share from the Mac app" },
        {
          type: "steps",
          steps: [
            {
              title: "Sign in",
              text: "Open **Settings → Account** and click **Sign In…**. Sharing needs an account; exporting does not.",
            },
            {
              title: "Turn on sharing in the export sheet",
              text: "Click **Export…**, turn on **Share link after export**, and optionally **Allow viewer comments on the share page**. Comments can only be chosen now; see [Comments and reactions](/docs/export-and-sharing/comments-and-reactions).",
            },
            {
              title: "Export",
              text: "Click **Export** and save the file. The sheet closes as soon as the file is written and the upload carries on in the background.",
            },
            {
              title: "Watch the upload on the project card",
              text: "In the library, the project's card shows **Uploading 42%…**, then **Creating share link…**. If it fails, the card says why.",
            },
            {
              title: "Copy the link",
              text: "Right-click the project card and choose **Copy Share Link**. Shared projects also appear under **Shared** in the [library](/docs/library) sidebar.",
            },
          ],
        },
        {
          type: "p",
          text: "For a quicker route, right-click a project in the library and choose **Share…**. CaptureCat exports an MP4 in the background with the project's export settings (the card shows **Exporting 42%…**), then uploads it. There is no save dialog, and comments are off for links made this way.",
        },
        { type: "h3", text: "Upload every export automatically" },
        {
          type: "p",
          text: "In **Settings → Account**, turn on **Sync exports to cloud** (\"Automatically upload every export to your library\"). While you are signed in, every video export then uploads as if you had ticked **Share link after export**. GIF exports never upload.",
        },
        { type: "h2", text: "Share from the web editor" },
        {
          type: "list",
          items: [
            "Click **Share** in the editor's top bar. CaptureCat exports an MP4 and uploads it; the button shows the progress, then **Creating link…** and **Shared**. Open it to copy the link.",
            "Or click **Export…** and turn on **Share link after export**. After the file is saved, the sheet shows **Uploading to share...**, **Finalizing share link...**, then the link with a **Copy** button. Closing the sheet does not stop the upload. If it fails, **Retry** uploads the same file again.",
            "Recordings made with the web recorder are saved as projects. Open one in the web editor and share it from there. See [Record in the browser](/docs/web-app/record).",
          ],
        },
        { type: "h2", text: "Uploads run in the background" },
        {
          type: "p",
          text: "You can keep recording and editing while a share uploads. Each project has at most one upload at a time; sharing it again while one is running does nothing. Uploads started in the Mac app also appear in your web library with a live progress bar, so you can watch them from another device.",
        },
        { type: "h2", text: "The link" },
        {
          type: "p",
          text: "Every share link has the form `https://capturecat.so/share/<video-id>` and never changes. Sharing the same project again replaces the video at the same link and keeps the old cut as a version; see [Versions](/docs/export-and-sharing/versions). With a [custom domain](/docs/teams/custom-domains), the same video also plays at `https://share.yourcompany.com/<video-id>`.",
        },
        {
          type: "list",
          items: [
            "**Start at a moment:** add `?t=` and a number of seconds, for example `https://capturecat.so/share/<video-id>?t=90`.",
            "**Markdown for AI tools:** add `.md` (`https://capturecat.so/share/<video-id>.md`) for a text version with the title, summary, chapters and timestamped transcript. Private and gated links return not found.",
          ],
        },
        { type: "h2", text: "What viewers see" },
        {
          type: "list",
          items: [
            "The video in a player tinted with your brand accent, with the title (the AI title if there is one, otherwise the file name), date and length.",
            "Your annotations as marks on the progress bar; text and callout annotations show their label on hover.",
            "Emoji reactions and a **Copy link** button, plus **Download** when you allow it and your call-to-action button when you set one. See [Share controls](/docs/export-and-sharing/share-controls).",
            "The AI summary and clickable chapters, when the share has them. See [AI titles, summaries and chapters](/docs/export-and-sharing/ai-summaries).",
            "A searchable **Transcript** with clickable timestamps, when the project had [captions](/docs/editing/captions) at share time.",
            "Comments, when you allowed them.",
          ],
        },
        { type: "h2", text: "Public and private" },
        {
          type: "p",
          text: "New links are public: anyone with the link can watch. To make one private, open the web library at [capturecat.so/app](https://capturecat.so/app), choose **Details & versions** from the video's **…** menu and turn off **Public link**. The share page and embeds then stop working for everyone, and the video stays in your library. Turn it back on to restore the same link. A change can take a few minutes to reach every location.",
        },
        { type: "h2", text: "What you can upload" },
        {
          type: "p",
          text: "Share links accept MP4, MOV and WebM files. Your plan sets a per-video size limit, a length limit, a number of new shares per day, and a total storage allowance. When an upload is refused, the message says which:",
        },
        {
          type: "table",
          head: ["Message", "What to do"],
          rows: [
            ["File too large (max …)", "Export at a lower resolution or quality, or trim the video."],
            ["Recording too long (max …)", "Trim the video, or split it into parts."],
            ["Daily upload limit reached (… per day)", "Wait until the next UTC day."],
            ["Storage limit reached (…). Delete shared videos or old versions before uploading more.", "Delete videos or old [versions](/docs/export-and-sharing/versions), or keep videos in [your own bucket](/docs/custom-storage), which does not count toward storage."],
          ],
        },
        { type: "h2", text: "Delete a link" },
        {
          type: "p",
          text: "In the web library, choose **Delete** from the video's **…** menu, or select several videos and click **Delete**. Deleting removes every version's file and the link stops working. It cannot be undone.",
        },
        { type: "callout", tone: "pro", text: PLAN_PAUSE_TEXT },
      ],
      faqs: [
        {
          question: "Is CaptureCat a Loom alternative for sharing screen recordings?",
          answer:
            "Yes. CaptureCat records and edits on your Mac or in the browser, then gives you a share link with a watch page, transcript, timestamped comments, reactions and viewer analytics. Recording, editing and exporting are free; only the hosted link is paid.",
        },
        {
          question: "Do viewers need a CaptureCat account to watch?",
          answer: "No. Anyone with a public link can watch, react and comment in a browser without signing in.",
        },
        {
          question: "Does the link change when I edit and re-share the video?",
          answer:
            "No. Sharing the same project again replaces the video at the existing link and keeps the previous cut in version history.",
        },
        {
          question: "Can I share a recording without uploading it?",
          answer:
            "Yes. Export a file and send it however you like. Uploading only happens when you turn on sharing, choose **Share…**, or turn on **Sync exports to cloud**.",
        },
      ],
      related: [
        "export-and-sharing/share-controls",
        "export-and-sharing/versions",
        "export-and-sharing/analytics",
        "export-and-sharing/embed",
      ],
      lastModified: CHECKED,
    },

    // ── Share controls ────────────────────────────────────────────────────
    {
      slug: "export-and-sharing/share-controls",
      title: "Password-protect, expire and limit a share link",
      navTitle: "Share controls",
      description:
        "Add a password, an expiry date or a view limit to a CaptureCat share link, allow downloads, and set a brand colour, call-to-action button and thumbnail.",
      summary:
        "Each share link has its own controls in the web dashboard: a password, an expiry date, a view limit, a download button, a brand accent colour, a call-to-action button and a custom thumbnail. Changes apply to the existing link; nothing needs to be shared again.",
      platforms: ["web"],
      plan: "pro",
      blocks: [
        { type: "h2", text: "Where to find them" },
        {
          type: "p",
          text: "Open your library at [capturecat.so/app](https://capturecat.so/app) and use the video's **…** menu:",
        },
        {
          type: "list",
          items: [
            "**Share settings** opens a dialog with downloads, password, expiry, view limit, brand accent, thumbnail, the team library switch and the embed code.",
            "**Details & versions** opens the video's page, with **Visibility**, **Access controls**, **Call to action** and **Version history** sections.",
          ],
        },
        { type: "p", text: "Both edit the same settings. In list view, the gear icon on a row opens **Share settings**." },
        { type: "h2", text: "All controls" },
        {
          type: "table",
          head: ["Control", "What it does"],
          rows: [
            ["**Public link**", "Off makes the video private: its share page and embeds stop working for everyone. On by default."],
            ["**Allow downloads**", "Adds a **Download** button to the share page and embeds, for the file of the live version. Off by default."],
            ["**Password**", "Viewers must enter it before watching."],
            ["**Expires**", "A date after which the link stops working."],
            ["**View limit**", "The number of views after which the link stops working. Empty means **Unlimited**."],
            ["**Brand accent**", "A hex colour that tints the player's progress bar, buttons and page glow. **Reset** returns to the default amber."],
            ["**Thumbnail**", "A JPEG, PNG or WebP image up to 5 MB, used as the poster in your library, on the share page and in link previews."],
            ["**Call to action**", "A button on the share page with your label and an https link."],
            ["**List on my profile**", "Shows the video on your [public profile](/docs/export-and-sharing/profile-and-playlists). On by default."],
            ["**Show version history**", "Lets viewers switch between [versions](/docs/export-and-sharing/versions)."],
            ["**Team library**", "Adds the video to your [team library](/docs/teams). Shown when you belong to a team."],
          ],
        },
        { type: "h2", text: "Add a password" },
        {
          type: "steps",
          steps: [
            {
              title: "Open the settings",
              text: "Choose **Share settings** from the video's **…** menu, or open **Details & versions** and go to **Access controls**.",
            },
            {
              title: "Turn on Password and type it",
              text: "To change an existing password, type the new one. Leaving the field blank keeps the current password.",
            },
            {
              title: "Save",
              text: "Click **Save** in the dialog, or **Save access controls** on the details page. Viewers now see \"This video is password protected.\" with a password field and a **Watch** button.",
            },
          ],
        },
        {
          type: "p",
          text: "To remove the password, turn **Password** off and save. Passwords are stored salted and hashed, never in plain text. After 10 wrong guesses from one IP address within 10 minutes, the page refuses further attempts for a while.",
        },
        { type: "h2", text: "Expiry dates and view limits" },
        {
          type: "list",
          items: [
            "**Expires:** the link works until the end of the chosen day in your browser's time zone. After that, viewers see \"This share link has expired.\" Clear the date and save to remove the expiry.",
            "**View limit:** each visit to the share page or an embed counts as one view, whether or not the viewer presses play. On a password-protected link only unlocked visits count. Once the limit is reached, viewers see \"This video has reached its view limit.\"",
            "Raise or clear either one at any time and the same link works again.",
          ],
        },
        {
          type: "p",
          text: "A link with a password, an expiry or a view limit never appears on your public profile, and its share page asks search engines not to index it.",
        },
        { type: "h2", text: "Add a call-to-action button" },
        {
          type: "steps",
          steps: [
            { title: "Open Details & versions", text: "From the video's **…** menu." },
            {
              title: "Fill in Call to action",
              text: "Enter a label of up to 60 characters, such as \"Book a demo\", and a link that starts with `https://`.",
            },
            {
              title: "Save",
              text: "The button appears on the share page. Clicks are counted in [analytics](/docs/export-and-sharing/analytics) as a play, watch, click funnel. **Remove** takes the button away.",
            },
          ],
        },
        { type: "h2", text: "Paused links" },
        { type: "p", text: PLAN_PAUSE_TEXT },
        {
          type: "callout",
          tone: "note",
          text: "Settings apply to the link straight away, but a cached copy elsewhere can take a few minutes to catch up. For something that must never be seen, make the video private or delete it rather than relying on an expiry date.",
        },
      ],
      faqs: [
        {
          question: "How do I password-protect a screen recording link?",
          answer:
            "In the CaptureCat web library, open the video's **Share settings**, turn on **Password**, type a password and click **Save**. Viewers must enter it before the video plays.",
        },
        {
          question: "Can I make a share link expire?",
          answer:
            "Yes. Set an **Expires** date in Share settings. The link stops working after that day, and clearing the date brings it back.",
        },
        {
          question: "Can viewers download my video?",
          answer:
            "Not from the share page unless you turn on **Allow downloads**, which adds a Download button. It is off for every new link.",
        },
      ],
      related: ["export-and-sharing/share-links", "export-and-sharing/analytics", "export-and-sharing/embed", "teams/custom-domains"],
      lastModified: CHECKED,
    },

    // ── Comments and reactions ────────────────────────────────────────────
    {
      slug: "export-and-sharing/comments-and-reactions",
      title: "Timestamped comments and emoji reactions on shared videos",
      navTitle: "Comments and reactions",
      description:
        "Let viewers leave timestamped comments and emoji reactions on a CaptureCat share link without an account, and read them in your dashboard.",
      summary:
        "Viewers can drop an emoji reaction at any moment of a shared video and, when you allow it, leave a comment pinned to the second they were watching. Neither needs an account.",
      platforms: ["mac", "web"],
      plan: "pro",
      blocks: [
        { type: "h2", text: "Turn on comments" },
        {
          type: "p",
          text: "Comments are chosen when a link is first created. In the export sheet (Mac or web), turn on **Share link after export**, then **Allow viewer comments on the share page**, and export.",
        },
        {
          type: "list",
          items: [
            "Links made with **Share…** on a Mac project card or the web editor's **Share** button start with comments off.",
            "Sharing the same project again replaces the video and keeps the link's original setting.",
            "There is no switch to turn comments on or off for an existing link yet.",
          ],
        },
        { type: "h2", text: "How viewers comment" },
        {
          type: "list",
          items: [
            "The comment box sits under the video. When the viewer starts typing, the comment is pinned to that moment of the video, shown as **at 1:23**.",
            "A name is optional (up to 40 characters); comments without one show as **Anonymous**.",
            "A comment can be up to 500 characters. **Post comment** publishes it.",
            "Each comment shows its timestamp; clicking it jumps the video there.",
          ],
        },
        { type: "h2", text: "Reactions" },
        {
          type: "list",
          items: [
            "Six reactions sit under the player: thumbs up, heart, fire, laughing, surprised and party popper. Each shows how many viewers chose it.",
            "A reaction is pinned to the moment the viewer tapped it. When anyone plays the video later, it floats up from that point on the progress bar.",
            "Each viewer has one reaction per video, remembered in their browser. Tapping a different one replaces it; tapping the same one again removes it.",
            "Reactions work on every public link, whether or not comments are on.",
          ],
        },
        { type: "h2", text: "Read comments" },
        {
          type: "p",
          text: "Comments appear on the share page and in the **Comments** section of the video's [analytics](/docs/export-and-sharing/analytics) page. For a video shared from the Mac app, each comment there has a button that opens the project in CaptureCat at that exact moment, so you can fix what the viewer pointed at.",
        },
        { type: "h2", text: "Limits" },
        {
          type: "list",
          items: [
            "One network (IP address) can post 10 comments every 10 minutes; past that, viewers are asked to slow down.",
            "A video accepts up to 500 comments and 2,000 reactions.",
            "Comments do not show in [embedded players](/docs/export-and-sharing/embed); the embed links to the share page.",
            "Comments cannot be edited or removed from the dashboard yet.",
          ],
        },
        {
          type: "callout",
          tone: "pro",
          text: "Comments are part of Pro. If your plan stops including them, comments are hidden from the share page.",
        },
      ],
      faqs: [
        {
          question: "Can viewers comment on a screen recording without an account?",
          answer:
            "Yes. On a CaptureCat share link with comments on, anyone can post a comment, with an optional name, pinned to the moment they were watching.",
        },
        {
          question: "Can I turn on comments after sharing?",
          answer:
            "Not yet. Comments are chosen in the export sheet when the link is created, and re-sharing the same project keeps that choice.",
        },
        {
          question: "Can viewers react with emoji at a specific moment?",
          answer:
            "Yes. Reactions are pinned to the second they were tapped and replay as floating emoji at that point for later viewers.",
        },
      ],
      related: ["export-and-sharing/share-links", "export-and-sharing/analytics", "export-and-sharing/share-controls"],
      lastModified: CHECKED,
    },

    // ── Analytics ─────────────────────────────────────────────────────────
    {
      slug: "export-and-sharing/analytics",
      title: "Screen recording analytics: views, watch time and drop-off",
      navTitle: "Analytics",
      description:
        "See how many people opened a CaptureCat share link, how far they watched, where they stopped, which countries and sites they came from, and CTA clicks.",
      summary:
        "Every share link has an analytics page in the web dashboard with views, plays, average watch point, completion rate, a watch heatmap, drop-off, player clicks, countries, referrers and comments. Viewers are counted anonymously; CaptureCat does not identify who watched.",
      platforms: ["web"],
      plan: "pro",
      blocks: [
        { type: "h2", text: "Open analytics" },
        {
          type: "p",
          text: "In the web library at [capturecat.so/app](https://capturecat.so/app), choose **Analytics** from the video's **…** menu, or click **Analytics** at the top of its **Details & versions** page.",
        },
        { type: "h2", text: "The headline numbers" },
        {
          type: "table",
          head: ["Number", "What it counts"],
          rows: [
            ["**Views**", "Visits to the share page or an embed, once per browser tab, whether or not the viewer pressed play. On a password-protected link, only visits that unlocked it."],
            ["**Pressed play**", "Visits that started playback."],
            ["**Avg. watch point**", "On average, how far into the video viewers got before they stopped."],
            ["**Watched to end**", "The share of visits that pressed play and reached the end."],
          ],
        },
        { type: "h2", text: "Charts and lists" },
        {
          type: "table",
          head: ["Section", "What it shows"],
          rows: [
            ["**Funnel**", "Shown when the video has a [call-to-action button](/docs/export-and-sharing/share-controls): pressed play, watched to the end, clicked the button, with the percentage at each step."],
            ["**Watch heatmap**", "How many viewers saw each second of the video. Peaks are moments people rewatch; dips are moments they skip."],
            ["**Where viewers stopped**", "How many sessions ended at each point. A cliff shows where you lose people."],
            ["**Player clicks by moment**", "Where in the video viewers clicked the player."],
            ["**Countries**", "The top 20 viewer countries."],
            ["**Referrers**", "The top 20 pages viewers came from, when their browser reports one. For an embed this is usually the page it is embedded in."],
            ["**Comments**", "Every comment with its timestamp; see [Comments and reactions](/docs/export-and-sharing/comments-and-reactions)."],
          ],
        },
        { type: "h2", text: "What is and is not tracked" },
        {
          type: "list",
          items: [
            "Viewers are anonymous. There are no names, emails or accounts behind the numbers, and no cookies: each tab gets a random id held in memory for that visit.",
            "Country comes from the viewer's network location; referrer comes from their browser.",
            "Watching is recorded in one-second steps, sent every 10 seconds and when the tab is hidden, so a viewer who closes the tab mid-video still counts up to where they stopped.",
            "Only you, the owner, can open a video's analytics.",
          ],
        },
        {
          type: "callout",
          tone: "tip",
          text: "Need to know exactly who watched? Share in your [team library](/docs/teams) so only teammates have it, or add a password and send it only to the people you mean.",
        },
      ],
      faqs: [
        {
          question: "Can I see who watched my screen recording?",
          answer:
            "Not by name. CaptureCat analytics are anonymous: you see how many viewers, how far they watched, where they stopped, their countries and the sites they came from, but not who they are.",
        },
        {
          question: "Does a view count if the viewer never presses play?",
          answer:
            "Yes. **Views** counts visits to the page. **Pressed play** and **Watched to end** show how many of those visits actually watched.",
        },
        {
          question: "Do embedded videos count in analytics?",
          answer:
            "Yes. Embeds use the same player and report views and watch time; the referrer is usually the page the video is embedded in.",
        },
      ],
      related: ["export-and-sharing/share-controls", "export-and-sharing/comments-and-reactions", "export-and-sharing/embed"],
      lastModified: CHECKED,
    },

    // ── Versions ──────────────────────────────────────────────────────────
    {
      slug: "export-and-sharing/versions",
      title: "Replace a shared video without changing the link",
      navTitle: "Versions",
      description:
        "Re-share an edited recording to the same CaptureCat link. Every earlier cut is kept as a version you can restore, delete or let viewers browse.",
      summary:
        "Sharing a project again replaces the video at its existing link instead of creating a new one. Earlier cuts stay in version history, where you can restore one, delete it to free storage, or let viewers switch between them.",
      platforms: ["mac", "web"],
      plan: "pro",
      blocks: [
        { type: "h2", text: "Replace the video at the same link" },
        {
          type: "p",
          text: "Edit the project and share it again, in any of the usual ways: **Share link after export**, **Share…** on the project card, or with **Sync exports to cloud** on. CaptureCat uploads the new export as the next version of the existing link, and when it finishes the link plays the new cut.",
        },
        {
          type: "list",
          items: [
            "The URL, comments, reactions, analytics and share settings all stay with the link.",
            "The new cut's transcript, annotation marks and on-device AI summary replace the old ones when it goes live, so they always describe the video that is playing.",
            "In the web editor this works for projects shared from the same browser, which remembers each project's link.",
            "If you deleted the video from your library, sharing again creates a new link.",
          ],
        },
        { type: "h2", text: "Version history" },
        {
          type: "p",
          text: "In the web library, choose **Details & versions** from the video's **…** menu. **Version history** lists every version with its number, date, length and size. The one playing now has a **Live** badge; one still uploading shows **Uploading**.",
        },
        {
          type: "steps",
          steps: [
            { title: "Open Details & versions", text: "From the video's **…** menu in the web library." },
            { title: "Find the version", text: "Versions are listed as v1, v2 and so on, with the date each was shared." },
            {
              title: "Click Restore",
              text: "The link plays that version right away. Newer versions stay in the history, so you can switch back.",
            },
          ],
        },
        { type: "h3", text: "Delete a version" },
        {
          type: "p",
          text: "Click the trash icon on a version and confirm **Delete version**. Its file is permanently deleted; the link and the other versions are unaffected. The live version cannot be deleted; restore another one first, or delete the whole video.",
        },
        { type: "h2", text: "Let viewers see past versions" },
        {
          type: "p",
          text: "Turn on **Show version history** in the **Visibility** section. The share page then shows a version picker (v1, v2, …), and `?v=2` on the link plays version 2. With it off, viewers can only play the live version.",
        },
        { type: "h2", text: "Storage" },
        {
          type: "p",
          text: "Every version counts toward your plan's storage until you delete it. Versions stored in [your own bucket](/docs/custom-storage) do not.",
        },
      ],
      faqs: [
        {
          question: "How do I update a shared screen recording without changing the link?",
          answer:
            "Edit the same project in CaptureCat and share it again. The new export replaces the video at the existing link, and the previous cut is kept in version history.",
        },
        {
          question: "Do comments and analytics survive a replacement?",
          answer:
            "Yes. They belong to the link, not to one version, so they carry over when you replace or restore the video.",
        },
        {
          question: "Can I undo a replacement?",
          answer: "Yes. Open **Details & versions**, find the earlier version and click **Restore**.",
        },
      ],
      related: ["export-and-sharing/share-links", "export-and-sharing/share-controls", "custom-storage"],
      lastModified: CHECKED,
    },

    // ── Embed ─────────────────────────────────────────────────────────────
    {
      slug: "export-and-sharing/embed",
      title: "Embed a screen recording on a website",
      navTitle: "Embed",
      description:
        "Embed a CaptureCat video in any web page with a script tag or an iframe, or paste the link into apps that support oEmbed. Share controls still apply.",
      summary:
        "Copy a script tag or an iframe from a video's **Share settings** and paste it into your page to get a responsive player. Passwords, expiry dates and view limits apply inside embeds too.",
      platforms: ["web"],
      plan: "pro",
      blocks: [
        {
          type: "steps",
          steps: [
            {
              title: "Open Share settings",
              text: "In the web library at [capturecat.so/app](https://capturecat.so/app), choose **Share settings** from the video's **…** menu.",
            },
            {
              title: "Copy the embed code",
              text: "Under **Embed**, click **Copy script** or **Copy iframe**.",
            },
            { title: "Paste it into your page", text: "Use the script where you can, and the iframe where scripts are not allowed." },
          ],
        },
        {
          type: "code",
          lang: "html",
          caption: "Script embed. It replaces itself with a responsive 16:9 player that loads lazily; several on one page each embed their own video.",
          code: SCRIPT_EMBED,
        },
        {
          type: "code",
          lang: "html",
          caption: "iframe embed, for sites that strip scripts.",
          code: IFRAME_EMBED,
        },
        { type: "h2", text: "What the embedded player shows" },
        {
          type: "list",
          items: [
            "The same player as the share page, with your brand accent, chapters, annotation marks and the **Download** button if you allow downloads.",
            "A **Watch on CaptureCat** badge in the corner that opens the full share page.",
            "No comments; viewers comment on the share page.",
            "Views and watch time count in the video's [analytics](/docs/export-and-sharing/analytics).",
          ],
        },
        { type: "h2", text: "Links that turn into players" },
        {
          type: "p",
          text: "Share pages advertise an oEmbed endpoint, `https://capturecat.so/api/oembed`, so apps that support oEmbed discovery can turn a pasted `capturecat.so/share/…` link into an embedded player. Share pages also carry video preview tags (Open Graph and Twitter player cards) with your thumbnail, for rich link previews. Gated and private links carry no preview.",
        },
        { type: "h2", text: "Embeds on a custom domain" },
        {
          type: "p",
          text: "With a [custom share domain](/docs/teams/custom-domains), the player is also served at `https://share.yourcompany.com/e/<video-id>`; use that address as the iframe `src`.",
        },
        {
          type: "callout",
          tone: "note",
          text: "Embeds follow the link's settings. A private video does not play, a password-protected one shows the password prompt inside the embed, and an expired or view-limited one shows the same message as the share page.",
        },
      ],
      faqs: [
        {
          question: "How do I embed a screen recording on my website?",
          answer:
            "Open the video's **Share settings** in the CaptureCat web library, click **Copy script** or **Copy iframe** under Embed, and paste the code into your page.",
        },
        {
          question: "Can I embed a password-protected video?",
          answer:
            "Yes. The embed shows the password prompt, and the video plays once the viewer enters the password.",
        },
      ],
      related: ["export-and-sharing/share-controls", "export-and-sharing/analytics", "teams/custom-domains"],
      lastModified: CHECKED,
    },

    // ── AI titles, summaries and chapters ─────────────────────────────────
    {
      slug: "export-and-sharing/ai-summaries",
      title: "AI titles, summaries and chapters for shared videos",
      navTitle: "AI titles and chapters",
      description:
        "CaptureCat turns a share's transcript into a title, a short summary and chapter markers, on-device on Macs with Apple Intelligence or from the dashboard.",
      summary:
        "When a project has captions, CaptureCat can turn the transcript into a share-page title, a two or three sentence summary and clickable chapters. On a Mac with Apple Intelligence this runs on-device as you share, and the web dashboard can also generate them on the server.",
      platforms: ["mac", "web"],
      plan: "pro",
      blocks: [
        { type: "h2", text: "What you get" },
        {
          type: "list",
          items: [
            "**Title:** replaces the file name on the share page and your public profile.",
            "**Summary:** two or three sentences in the description box under the video.",
            "**Chapters:** three to eight labelled moments, shown as pills under the video; clicking one jumps there.",
            "All three are also in the share link's Markdown version (`/share/<video-id>.md`).",
          ],
        },
        { type: "h2", text: "It needs a transcript" },
        {
          type: "p",
          text: "Everything is generated from the transcript, which comes from the project's captions. Generate [captions](/docs/editing/captions) in the editor before you share. A share without captions has no transcript and no AI summary.",
        },
        { type: "h2", text: "On-device on the Mac" },
        {
          type: "list",
          items: [
            "Needs macOS 26 or later with Apple Intelligence turned on.",
            "Runs automatically every time you share or re-share, using Apple's on-device model. The transcript is not sent to any AI service for this step.",
            "If the model is unavailable or fails, the share still completes, just without a title, summary or chapters.",
            "Shares from the web editor include the transcript but no on-device summary.",
          ],
        },
        { type: "h2", text: "From the web dashboard" },
        {
          type: "steps",
          steps: [
            { title: "Open the video's menu", text: "In the web library, click the video's **…** menu." },
            {
              title: "Choose Generate AI summary",
              text: "CaptureCat sends the share's transcript text (not the video) to Google Gemini on its server and saves the result. A message shows the new title.",
            },
          ],
        },
        {
          type: "p",
          text: "This replaces any existing title, summary and chapters, and works for videos shared from the Mac or the web. It fails with \"No transcript for this video yet\" when the share has no transcript, and you can run it up to five times a minute.",
        },
        {
          type: "callout",
          tone: "pro",
          text: "AI titles, summaries and chapters are part of Pro, both on-device and with **Generate AI summary** in the dashboard.",
        },
      ],
      faqs: [
        {
          question: "Does CaptureCat send my video to an AI service?",
          answer:
            "No. On the Mac, titles and chapters are made on-device. The dashboard's **Generate AI summary** sends only the transcript text to Google Gemini, never the video file.",
        },
        {
          question: "Why doesn't my shared video have chapters?",
          answer:
            "Chapters come from the transcript. Add captions in the editor and share again, on a Mac with Apple Intelligence, or use **Generate AI summary** in the web library.",
        },
      ],
      related: ["editing/captions", "export-and-sharing/share-links", "export-and-sharing/profile-and-playlists"],
      lastModified: CHECKED,
    },

    // ── Profile and playlists ─────────────────────────────────────────────
    {
      slug: "export-and-sharing/profile-and-playlists",
      title: "Public profile page and playlists for your videos",
      navTitle: "Profile and playlists",
      description:
        "Claim a capturecat.so/username page that lists the videos you choose, and organise your shared videos into private playlists in the web library.",
      summary:
        "Claim a username in **Settings** and `capturecat.so/<username>` lists your public share links with your bio and website. Playlists are private folders in your web library for grouping shared videos.",
      platforms: ["web"],
      plan: "pro",
      blocks: [
        { type: "h2", text: "Claim your profile" },
        {
          type: "steps",
          steps: [
            {
              title: "Open Settings",
              text: "In the web dashboard, open [Settings](https://capturecat.so/app/settings) and find **Public profile**.",
            },
            {
              title: "Choose a username",
              text: "3 to 30 characters: lowercase letters, numbers, hyphens and underscores, starting and ending with a letter or number. A tick or cross shows whether it is available.",
            },
            {
              title: "Add a bio and website",
              text: "**Bio** is up to 200 characters. **Website** must be an `https://` link. Both are optional.",
            },
            {
              title: "Click Save profile",
              text: "Your page is live at `capturecat.so/<username>`. **View** opens it.",
            },
          ],
        },
        {
          type: "p",
          text: "Changing your username later breaks the old profile address. Some names, such as `pricing`, `docs` and `admin`, are reserved.",
        },
        { type: "h2", text: "Which videos appear" },
        {
          type: "p",
          text: "Your profile lists up to 100 of your newest videos that are public, have no password, expiry or view limit, and have **List on my profile** on. Every video starts with it on; turn it off in the video's **Details & versions** page to keep a public link off your profile. Each video shows its AI title and summary when it has them.",
        },
        { type: "h2", text: "Playlists" },
        {
          type: "list",
          items: [
            "**Create:** in the web library, click **New playlist**, type a name (up to 60 characters) and click **Add**.",
            "**Add a video:** in the video's **…** menu, open **Playlists** and pick one. A tick shows the playlists it is already in; picking it again removes it. A video can be in several playlists.",
            "**Browse:** your playlists are listed in the library and in the sidebar under **Playlists**; click one to filter the library.",
            "**Delete:** select the playlist and click **Delete playlist**. The videos stay in your library.",
          ],
        },
        {
          type: "p",
          text: "Playlists are private to you and do not change who can watch a video. You can have up to 100 playlists of up to 500 videos each.",
        },
      ],
      faqs: [
        {
          question: "Can I have a public page that lists my screen recordings?",
          answer:
            "Yes. Claim a username in CaptureCat's web Settings and `capturecat.so/<username>` lists your public videos with your bio and website.",
        },
        {
          question: "How do I hide a video from my profile but keep the link working?",
          answer:
            "Turn off **List on my profile** on the video's Details & versions page, or add a password, expiry or view limit. The link keeps working either way.",
        },
      ],
      related: ["export-and-sharing/share-controls", "export-and-sharing/ai-summaries", "export-and-sharing/share-links"],
      lastModified: CHECKED,
    },
  ],
};
