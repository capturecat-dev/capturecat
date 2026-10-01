/**
 * The web dashboard's Library (app.capturecat.so): an upload from the Mac app
 * lands at the top of the list, its link is copied, the views tick over.
 * Sidebar labels are the real ones (components/dashboard/app-sidebar.tsx).
 */
import { DemoFrame } from "./parts";
import { useOffscreenPause } from "./hooks";

const ROWS = [
  { t: "Onboarding tour", v: "Public", views: "1,284", d: "2 days ago", i: 1 },
  { t: "Billing walkthrough", v: "Private", views: "312", d: "Last week", i: 2 },
  { t: "Release notes 1.1", v: "Public", views: "4,019", d: "Sep 12", i: 0 },
];

export function DashboardDemo() {
  const ref = useOffscreenPause<HTMLDivElement>();
  return (
    <div ref={ref} className="ccd" aria-hidden>
      <DemoFrame>
        <div className="ccd-mini ccd-live ccd-dash">
          <div className="ccd-urlbar">
            <span className="ccd-lights">
              <i />
              <i />
              <i />
            </span>
            <span className="ccd-url">
              <b>app.capturecat.so</b>
            </span>
          </div>
          <div className="ccd-webapp ccd-dash-app">
            <div className="ccd-webside">
              <span className="is-on">Library</span>
              <span>Record</span>
              <span>Projects</span>
              <span>Team</span>
              <span>Settings</span>
              <span>Billing</span>
            </div>
            <div className="ccd-dash-main">
              <div className="ccd-dash-head">
                <b>Library</b>
                <span className="ccd-dash-search">Search videos</span>
              </div>
              <div className="ccd-dash-list">
                <div className="ccd-dash-row ccd-dash-new">
                  <i data-i={3} />
                  <span>
                    <b>Launch video</b>
                    <small className="ccd-dash-up">
                      <span className="ccd-bar">
                        <i />
                      </span>
                    </small>
                    <small className="ccd-dash-done">Just now · 0:12</small>
                  </span>
                  <em className="ccd-dash-badge">Public</em>
                  <span className="ccd-dash-views">
                    <span className="ccd-dash-v0">0</span>
                    <span className="ccd-dash-v1">3</span>
                  </span>
                </div>
                <div className="ccd-dash-rows">
                  {ROWS.map((r) => (
                    <div key={r.t} className="ccd-dash-row">
                      <i data-i={r.i} />
                      <span>
                        <b>{r.t}</b>
                        <small>{r.d}</small>
                      </span>
                      <em className={`ccd-dash-badge ${r.v === "Private" ? "is-private" : ""}`}>{r.v}</em>
                      <span className="ccd-dash-views">{r.views}</span>
                    </div>
                  ))}
                </div>
              </div>
              <div className="ccd-dash-toast">✓ Link copied · capturecat.so/share/7Kq2fX</div>
            </div>
          </div>
        </div>
      </DemoFrame>
    </div>
  );
}
