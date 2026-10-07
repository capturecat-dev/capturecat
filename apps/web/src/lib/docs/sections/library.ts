import type { DocSection } from "../types";

/**
 * Checked against apps/macos/CaptureCat: ProjectBrowserViewController.swift
 * (sidebar, type filter, search, card menus), CaptureTextIndex.swift and
 * CaptureSearchSeek.swift (OCR index, ranking, jump to frame),
 * ProjectLibrary.swift (folders, pins, shared), ReminderCenter.swift,
 * TextCaptureService.swift, Note.swift, NoteViewerWindowController.swift,
 * Resources/Info.plist (NSServices) and the menus in CaptureCatAppDelegate.swift
 * and StatusMenuBuilder.swift.
 */
const CHECKED = "2026-10-07";

export const LIBRARY: DocSection = {
  id: "library",
  title: "Library and notes",
  description: "Search inside your recordings, organise captures, and capture notes.",
  pages: [
    {
      slug: "library",
      title: "Search text inside your screen recordings on Mac",
      navTitle: "Library and search",
      description:
        "Find any recording by the words that were on screen. CaptureCat reads your captures with on-device OCR, and Command-K jumps straight to the matching frame.",
      summary:
        "Every recording and screenshot in your CaptureCat library is read with on-device text recognition, so you can press Command-K, type a word that was on screen, and open the recording at the frame where it appears. Nothing is uploaded to build or search the index.",
      platforms: ["mac"],
      blocks: [
        { type: "h2", text: "Open the library" },
        {
          type: "p",
          text: "Choose **Browse Captures...** from the CaptureCat menu bar icon or the **File** menu (Command-O), or click **Captures** at the top left of the editor. When a project is open, **Back to Editor** returns to it.",
        },
        {
          type: "p",
          text: "The window has a sidebar on the left (**All Captures**, **Pinned**, **Shared** and your folders) and a grid of captures on the right. Click a capture to open it. Above the grid, the type filter narrows the grid to **All**, **Videos**, **Images** or **Notes**, and each segment shows how many captures it holds. Your choice is remembered between launches.",
        },
        { type: "h2", text: "Search with Command-K" },
        {
          type: "steps",
          steps: [
            {
              title: "Focus the search bar",
              text: "Press **Command-K** (**View → Search Captures**) or click the **Search captures…** bar under the header.",
            },
            {
              title: "Type what was on screen",
              text: "Type one or more words: an error message, a customer name, a setting, a URL. The grid filters as you type, and a suggestions list shows the top five matches.",
            },
            {
              title: "Pick a result",
              text: "Use the arrow keys and **Return**, or click. A video opens in the editor with the playhead on the frame that matched best. A note opens in the note viewer.",
            },
          ],
        },
        {
          type: "p",
          text: "When a capture matched on its text rather than its title, its card shows a one-line snippet of the text around the match, so you can see why it was found. Video suggestions also show the time of the matching frame, for example `2:41`.",
        },
        {
          type: "p",
          text: "With the search bar empty, the suggestions list shows your five most recent searches. Press **Escape** to close the suggestions, press it again to clear the search, and once more to return to the grid.",
        },
        { type: "h2", text: "How matching works" },
        {
          type: "list",
          items: [
            "**Every word must match.** `stripe invoice` finds captures that show both words, anywhere in the recording.",
            "**Case and accents are ignored**, and words match inside longer words, so `invoice` also finds `Invoices`.",
            "**Titles count too.** Captures whose name matches come first, then captures that matched on screen text, ordered by how many times your words appear.",
            "**Notes are searched by their full text.**",
            "**The grid follows the sidebar.** In **Pinned** or a folder, the grid only shows matches from there; in **All Captures** it includes notes too. The suggestions list always searches your whole library.",
          ],
        },
        { type: "h2", text: "Jump to the exact frame" },
        {
          type: "p",
          text: "Opening a video while a search is active lands the playhead on the indexed frame with the most hits for your words. The position accounts for your edits: if you trimmed the start or added speed regions, CaptureCat converts the recording time to the edited timeline, and a match inside a trimmed-away part lands at the nearest edge that is still in the video.",
        },
        { type: "h2", text: "What gets indexed" },
        {
          type: "list",
          items: [
            "**Videos:** CaptureCat samples a frame about every 2 seconds and reads its text, up to 40 frames per recording. Longer recordings are sampled at a wider interval so the whole recording is covered.",
            "**Screenshots:** the image is read once.",
            "**Notes:** the note's text, as you saved it.",
            "**New captures** are queued for indexing as soon as they are saved. A capture is indexed again only when its media file changes.",
          ],
        },
        {
          type: "p",
          text: "Indexing runs in the background at low priority. It starts a few seconds after launch and pauses while you are recording or exporting, so a capture you just made may take a moment to become searchable by its text. Its title is searchable immediately.",
        },
        { type: "h2", text: "Privacy" },
        {
          type: "p",
          text: "Text recognition uses Apple's Vision framework on your Mac. The index is stored locally in CaptureCat's Application Support folder (`SearchIndex`) and is never uploaded. Signing out, or having no account at all, does not affect search.",
        },
        {
          type: "callout",
          tone: "tip",
          title: "Find private data before you share",
          text: "Search for an email address, a domain or a key prefix to find every recording that shows it, then blur it. See [Blur and privacy](/docs/editing/privacy).",
        },
        { type: "h2", text: "Library shortcuts" },
        {
          type: "shortcuts",
          rows: [
            ["⌘O", "Browse Captures"],
            ["⌘K", "Search captures"],
            ["⌘1", "Show all captures"],
            ["⌘2", "Show videos"],
            ["⌘3", "Show images"],
            ["⌘4", "Show notes"],
            ["⌘-click or ⇧-click", "Select several captures"],
            ["⌫", "Delete the selected captures"],
          ],
        },
        { type: "h2", text: "Search from an AI agent" },
        {
          type: "p",
          text: "The same index is available to AI agents through the `search_captures` tool on CaptureCat's built-in MCP server. Results include the time of the best matching frame, so an agent can open or render it. See [AI agents](/docs/ai-agents).",
        },
      ],
      faqs: [
        {
          question: "Can I search for text inside a screen recording on a Mac?",
          answer:
            "Yes. CaptureCat reads the text in your recordings and screenshots with on-device OCR. Press Command-K in the library, type a word that was on screen, and pick the result to open the recording at that frame.",
        },
        {
          question: "Is my screen content uploaded to make it searchable?",
          answer:
            "No. Text recognition runs on your Mac with Apple's Vision framework, and the index stays in CaptureCat's local Application Support folder.",
        },
        {
          question: "Why doesn't a recording I just made show up when I search for its text?",
          answer:
            "Indexing runs in the background and pauses while you record or export, so a new recording can take a moment to be read. You can always find it by its title straight away.",
        },
        {
          question: "Does search read every frame?",
          answer:
            "It reads a sampled frame about every 2 seconds, up to 40 frames per recording. Text that is on screen for a couple of seconds or more is almost always caught.",
        },
      ],
      related: ["library/organize", "library/notes", "ai-agents/tools"],
      lastModified: CHECKED,
    },
    {
      slug: "library/notes",
      title: "Capture highlighted text as a note on Mac",
      navTitle: "Notes",
      description:
        "Save highlighted text from any Mac app as a CaptureCat note with the Services menu, or from the clipboard. Notes are searchable beside your recordings.",
      summary:
        "Highlight text in any app, right-click and choose **Services → Capture Text in CaptureCat** to save it as a note without leaving what you are doing. Notes live in your library next to your recordings, with search and reminders.",
      platforms: ["mac"],
      blocks: [
        { type: "h2", text: "Capture text from any app" },
        {
          type: "steps",
          steps: [
            {
              title: "Highlight the text",
              text: "Select text in Safari, Mail, Notes, a PDF, a terminal, or any other app that supports the macOS Services menu.",
            },
            {
              title: "Send it to CaptureCat",
              text: "Right-click the selection and choose **Services → Capture Text in CaptureCat**. You can also find it in the app's own menu under **App name → Services**.",
            },
            {
              title: "Carry on",
              text: "The note is saved quietly in the background, with the name of the app it came from. CaptureCat does not come to the front.",
            },
          ],
        },
        {
          type: "callout",
          tone: "tip",
          title: "Give it a keyboard shortcut",
          text: "macOS lets you assign a shortcut to any Services item. Open **System Settings → Keyboard → Keyboard Shortcuts → Services**, find **Capture Text in CaptureCat** under Text, and set a shortcut.",
        },
        { type: "h2", text: "New note from the clipboard" },
        {
          type: "p",
          text: "If an app does not offer the Services menu, copy the text and choose **File → New Note from Clipboard** (Option-Command-N) in CaptureCat. The note opens straight away so you can edit it. If the clipboard has no text, the Mac beeps and nothing is created.",
        },
        { type: "h2", text: "The note viewer" },
        {
          type: "p",
          text: "Click a note in the library to open it in its own window. Each note gets one window; opening it again brings that window forward.",
        },
        {
          type: "list",
          items: [
            "**Edit the text.** Changes save automatically as you type.",
            "**See where it came from.** The line under the title shows the source app, when known, and when the note was captured.",
            "**Remind Me** schedules a notification for the note. See [Reminders](/docs/library/organize#reminders).",
            "**Delete** removes the note after you confirm. This cannot be undone.",
          ],
        },
        {
          type: "p",
          text: "A note's title is its first line of text, up to 60 characters. A note with no text is shown as **Untitled Note**.",
        },
        { type: "h2", text: "Find notes" },
        {
          type: "list",
          items: [
            "Notes appear in **All Captures**, mixed with your recordings by date, and on their own under the **Notes** filter (Command-4).",
            "Command-K search matches a note's full text, not just its title.",
            "Notes cannot be pinned, shared, or added to folders. Those are for recordings and screenshots.",
          ],
        },
        {
          type: "p",
          text: "Notes are stored on your Mac in CaptureCat's Application Support folder (`Notes`). They are not synced or uploaded.",
        },
        { type: "h2", text: "Notes and AI agents" },
        {
          type: "p",
          text: "Agents connected to CaptureCat's MCP server can read your notes with the `list_notes` tool, and `search_captures` searches notes along with recordings. See [MCP tools reference](/docs/ai-agents/tools).",
        },
      ],
      faqs: [
        {
          question: "How do I save highlighted text as a note on my Mac?",
          answer:
            "Highlight the text, right-click it and choose Services → Capture Text in CaptureCat. The note is saved in the background and appears in your CaptureCat library.",
        },
        {
          question: "Why don't I see Capture Text in CaptureCat in the Services menu?",
          answer:
            "The item only appears when text is selected, and only in apps that support Services. Open CaptureCat at least once, then check that Capture Text in CaptureCat is ticked in System Settings → Keyboard → Keyboard Shortcuts → Services.",
        },
        {
          question: "Are notes uploaded anywhere?",
          answer: "No. Notes are stored on your Mac only.",
        },
      ],
      related: ["library", "library/organize", "getting-started/keyboard-shortcuts"],
      lastModified: CHECKED,
    },
    {
      slug: "library/organize",
      title: "Organize captures with folders, pins and reminders",
      navTitle: "Folders, pins and reminders",
      description:
        "Sort your CaptureCat recordings into folders, pin the ones you use most, filter to shared captures, and set reminders that notify you later.",
      summary:
        "The library sidebar holds **All Captures**, **Pinned**, **Shared** and your own folders. Right-click any capture to pin it, file it in a folder, or set a reminder.",
      platforms: ["mac"],
      blocks: [
        { type: "h2", text: "The sidebar" },
        {
          type: "table",
          head: ["Item", "Shows"],
          rows: [
            ["**All Captures**", "Every recording, screenshot and note. Pinned captures come first, then everything else, newest first."],
            ["**Pinned**", "Captures you pinned."],
            ["**Shared**", "Captures you have shared with a link. Right-click one and choose **Copy Share Link** to copy it again."],
            ["Your folders", "The captures you filed in that folder."],
          ],
        },
        {
          type: "p",
          text: "Click the sidebar button at the top left to hide or show the sidebar. The type filter (**All**, **Videos**, **Images**, **Notes**) and search work inside whichever sidebar item is selected.",
        },
        { type: "h2", text: "Folders" },
        {
          type: "steps",
          steps: [
            {
              title: "Create a folder",
              text: "Click **New Folder...** under **FOLDERS** in the sidebar, enter a name and click **Create**. The new folder opens.",
            },
            {
              title: "Add captures",
              text: "Drag a capture onto the folder in the sidebar, or right-click it and choose **Add to Folder**, then the folder. **Add to Folder → New Folder...** creates a folder and files the capture in one step.",
            },
            {
              title: "Remove a capture",
              text: "Right-click it and choose **Remove from Folder**. The capture stays in your library.",
            },
          ],
        },
        {
          type: "list",
          items: [
            "A capture can be in one folder at a time. Adding it to another folder moves it.",
            "Right-click a folder to **Rename Folder...** or **Delete Folder**. Deleting a folder never deletes the captures in it; they stay in **All Captures**.",
            "Folders hold recordings and screenshots. Notes are not filed in folders.",
          ],
        },
        { type: "h2", text: "Pins" },
        {
          type: "p",
          text: "Right-click a capture and choose **Pin**. Pinned captures show a pin badge, sit at the top of **All Captures** and are listed under **Pinned**. Choose **Unpin** to remove it.",
        },
        { type: "h2", text: "Reminders" },
        {
          type: "p",
          text: "Right-click a recording, screenshot or note and open **Remind Me** (notes also have a **Remind Me** button in the note viewer).",
        },
        {
          type: "table",
          head: ["Choice", "When you are notified"],
          rows: [
            ["**Tomorrow**", "Tomorrow at 9:00"],
            ["**In 3 Days**", "In three days at 9:00"],
            ["**In 1 Week**", "In seven days at 9:00"],
            ["**In 30 Days**", "In thirty days at 9:00"],
            ["**Custom Date…**", "Any future date and time you pick, then **Set Reminder**"],
          ],
        },
        {
          type: "p",
          text: "The card shows a badge such as `in 3d` until the reminder fires, and the menu reads **Remind Me (in 3d)**. Choose **Clear Reminder** to cancel it. When the notification arrives, click it to open the recording in the editor or the note in its viewer.",
        },
        {
          type: "callout",
          tone: "note",
          text: "Reminders are macOS notifications, so CaptureCat asks for notification permission the first time you set one. If notifications are off, the reminder date is still saved but no banner appears; turn them on in **System Settings → Notifications → CaptureCat**.",
        },
        { type: "h2", text: "Rename, duplicate and delete" },
        {
          type: "list",
          items: [
            "**Rename...** changes a capture's name, which is also what Command-K matches first.",
            "**Duplicate** makes an independent copy of the project, media included, named with `Copy` on the end. Useful for trying a different edit.",
            "**Delete...** removes the capture after you confirm. To delete several, Command-click or Shift-click to select them and press Delete. This cannot be undone.",
          ],
        },
        {
          type: "p",
          text: "Folders, pins and shared marks are stored in one library file in CaptureCat's Application Support folder, separate from your projects. Organizing a capture never rewrites the project itself.",
        },
      ],
      faqs: [
        {
          question: "Does deleting a folder delete my recordings?",
          answer: "No. Deleting a folder only removes the folder. Its recordings stay in All Captures.",
        },
        {
          question: "Can a recording be in more than one folder?",
          answer: "No. Each capture is in at most one folder; adding it to another folder moves it there. Use pins to keep a capture handy across folders.",
        },
        {
          question: "What does the Shared filter show?",
          answer:
            "Every capture you have shared with a CaptureCat link from this Mac. Right-click one and choose Copy Share Link to copy its link again.",
        },
      ],
      related: ["library", "library/notes", "export-and-sharing/share-links"],
      lastModified: CHECKED,
    },
  ],
};
