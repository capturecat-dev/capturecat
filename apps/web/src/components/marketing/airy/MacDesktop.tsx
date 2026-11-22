import { ScreenPicture } from "./IosApp";
import { BinIcon, BrowserIcon, ChatIcon, FilesIcon, MusicIcon, NotesIcon, SettingsIcon } from "./DockIcons";

/**
 * The laptop's screen as a desktop: the hero's own dusk wallpaper, a slim
 * menu bar, the REAL CaptureCat editor window (a screenshot of the Mac app,
 * 1400 × 906, captured through the app's own renderer on a demo recording)
 * and a dock along the bottom. The menu bar and dock are drawn here, not
 * baked into the screenshot, so they stay crisp at every size. Every glyph
 * is original (DockIcons.tsx — Mac-style, but no real app's icon); only the
 * CaptureCat icon is a real app icon.
 * Decorative: the device composition carries the label.
 */
export function MacDesktop({ priority = false }: { priority?: boolean }) {
  return (
    <div className="air-mac-desk" aria-hidden>
      <div className="air-mac-menubar">
        <span className="air-mac-menu">
          <b>CaptureCat</b>
          <span>File</span>
          <span>Edit</span>
          <span>View</span>
          <span>Window</span>
          <span>Help</span>
        </span>
        <span className="air-mac-menu">
          <span>Tue 9:41</span>
        </span>
      </div>
      <div className="air-mac-window">
        <ScreenPicture name="mac-editor" width={1400} height={906} priority={priority} />
      </div>
      <div className="air-mac-dock">
        <span className="air-dock-app air-dock-app--cc">
          <picture>
            <source srcSet="/media/capturecat-mac-icon.webp" type="image/webp" />
            <img src="/media/capturecat-mac-icon.png" alt="" width={128} height={128} decoding="async" />
          </picture>
          <i className="air-dock-dot" />
        </span>
        {DOCK.map(({ name, Icon, running }) => (
          <span key={name} className="air-dock-app">
            <Icon />
            {running && <i className="air-dock-dot" />}
          </span>
        ))}
        <span className="air-dock-divider" />
        <span className="air-dock-app air-dock-app--bin">
          <BinIcon />
        </span>
      </div>
    </div>
  );
}

/** The other apps in the dock: original Mac-style icons (DockIcons.tsx). */
const DOCK = [
  { name: "files", Icon: FilesIcon, running: true },
  { name: "browser", Icon: BrowserIcon, running: true },
  { name: "chat", Icon: ChatIcon, running: false },
  { name: "notes", Icon: NotesIcon, running: false },
  { name: "music", Icon: MusicIcon, running: false },
  { name: "settings", Icon: SettingsIcon, running: false },
];
