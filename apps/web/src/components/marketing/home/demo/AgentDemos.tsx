/**
 * The agents page: a coding agent driving the editor over MCP (real tool
 * names from the app's MCP catalog), and the Connect AI Agents window
 * (AgentSetupWindowController) reached from the menu bar icon.
 */
import { DemoFrame, EditorMock } from "./parts";
import { MenuBar } from "./RecordingScene";
import { useOffscreenPause } from "./hooks";

const PROMPT =
  'claude "add zooms on my clicks, put it on the Sequoia wallpaper, check a frame, export"';

const LINES: Array<[string, string]> = [
  ["describe_project", "3 click clusters, 1 typing burst"],
  ["add_effect", "zoom 0:01–0:05 · 1.9×"],
  ["add_effect", "zoom 0:05–0:08 · 1.9×"],
  ["set_style", "wallpaper Sequoia · padding 80"],
  ["render_frames", "t = 2.0 s → frame-2.0.png"],
  ["export_project", "~/Movies/launch-video.mp4"],
];

export function AgentSessionDemo() {
  const ref = useOffscreenPause<HTMLDivElement>();
  return (
    <div ref={ref} className="ccd" aria-hidden>
      <DemoFrame>
        <div className="ccd-agent">
          <div className="ccd-agent-grid">
            <div className="ccd-agent-term">
              <div className="ccd-agent-bar">
                <span className="ccd-lights">
                  <i />
                  <i />
                  <i />
                </span>
                claude
              </div>
              <div className="ccd-agent-body">
                <p className="ccd-agent-prompt">
                  <span className="ccd-agent-dollar">$ </span>
                  {Array.from(PROMPT).map((ch, i) => (
                    <span
                      key={i}
                      className="ccd-pch"
                      style={{ animationDelay: `${(i * 0.022).toFixed(3)}s` }}
                    >
                      {ch}
                    </span>
                  ))}
                </p>
                {LINES.map(([tool, note], i) => (
                  <p
                    key={i}
                    className={`ccd-agent-line ccd-agent-line-${i + 1}`}
                  >
                    <b>⏺ {tool}</b> {note}
                  </p>
                ))}
                <p className="ccd-agent-line ccd-agent-line-7 ccd-agent-ok">
                  ✓ Done. Two zooms, new wallpaper, exported.
                </p>
              </div>
            </div>
            <div className="ccd-agent-ed">
              <EditorMock
                script="agent"
                title="Launch video"
                duration={10}
                lanes={[
                  { name: "VIDEO" },
                  {
                    name: "EFFECTS",
                    blocks: [
                      {
                        className: "ccd-b1",
                        left: 11,
                        width: 35,
                        label: "Zoom 1.9×",
                      },
                      {
                        className: "ccd-b2",
                        left: 52,
                        width: 32,
                        label: "Zoom 1.9×",
                      },
                    ],
                  },
                ]}
                overlays={<div className="ccd-agent-flash" />}
              />
            </div>
          </div>
        </div>
      </DemoFrame>
    </div>
  );
}

const CLIENTS = [
  [
    "Claude Code",
    "Registers for every project on this Mac (user scope) via Terminal.",
    null,
  ],
  [
    "Claude Desktop",
    "Opens a one-click extension bundle in Claude Desktop.",
    "Installed",
  ],
  ["Cursor", "One click — Cursor confirms the server.", "Installed"],
  [
    "Codex",
    "Registers globally via Terminal — the Codex app reads the same config.",
    null,
  ],
  [
    "Gemini CLI",
    "Registers for every project (user scope) via Terminal.",
    null,
  ],
  ["VS Code", "Opens VS Code's install prompt for the server.", "Installed"],
  [
    "Windsurf & others",
    "Copies the standard mcpServers JSON for any client's config.",
    null,
  ],
] as const;

export function ConnectAgentsDemo() {
  const ref = useOffscreenPause<HTMLDivElement>();
  return (
    <div ref={ref} className="ccd" aria-hidden>
      <DemoFrame>
        <div className="ccd-stage ccd-connect">
          <div className="ccd-desk" />
          <MenuBar>
            <img
              className="ccd-menubar-icon"
              src="/apple-icon.png"
              alt=""
              width={16}
              height={16}
              loading="lazy"
              decoding="async"
            />
          </MenuBar>
          <div className="ccd-menu ccd-menu--connect">
            {[
              ["New Recording...", "⌘N"],
              ["Browse Captures...", "⌘O"],
              null,
              ["Settings…", "⌘,"],
              ["Connect AI Agents...", ""],
              ["Check for Updates...", ""],
            ].map((item, i) =>
              item ? (
                <span
                  key={i}
                  className={`ccd-menu-item ${i === 4 ? "ccd-menu-item--hot" : ""}`}
                >
                  {item[0]}
                  <em>{item[1]}</em>
                </span>
              ) : (
                <i key={i} />
              ),
            )}
          </div>
          <div className="ccd-agents-win">
            <div className="ccd-agents-head">
              <span className="ccd-lights">
                <i />
                <i />
                <i />
              </span>
            </div>
            <b className="ccd-agents-title">Connect AI Agents</b>
            <p className="ccd-agents-sub">
              Let Claude, Cursor, Codex or any MCP client drive CaptureCat —
              record, edit, see rendered frames, and export. Pick your client:
            </p>
            <div className="ccd-agents-card">
              {CLIENTS.map(([name, detail, badge], i) => (
                <div key={name} className="ccd-agents-row">
                  <i data-i={i} />
                  <span>
                    <b>
                      {name}
                      {badge && <em>{badge}</em>}
                    </b>
                    <small>{detail}</small>
                  </span>
                  <span
                    className={`ccd-key ${i === 2 ? "ccd-agents-hot" : ""}`}
                  >
                    {name.startsWith("Windsurf") ? "Copy JSON" : "Install"}
                    {i === 2 && <span className="ccd-rec-tint" />}
                  </span>
                </div>
              ))}
            </div>
            <div className="ccd-agents-note">
              Opened Cursor — confirm the install prompt there.
            </div>
          </div>
        </div>
      </DemoFrame>
    </div>
  );
}
