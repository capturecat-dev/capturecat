/**
 * The hosted side, rebuilt: a share page (player with comment markers on the
 * scrubber, comments pinned to the second) and the analytics tab for the same
 * video (views, watch time, completion, the retention curve with its drop).
 */
import { DemoFrame } from "./parts";
import { useOffscreenPause } from "./hooks";

const COMMENTS = [
  { name: "Maya", time: "0:17", body: "Love this zoom on the name field." },
  { name: "Theo", time: "0:34", body: "Can the team picker open a bit slower?" },
  { name: "Ines", time: "1:08", body: "Ship it. Adding this to the docs." },
];

export function SharePageDemo() {
  const ref = useOffscreenPause<HTMLDivElement>();
  return (
    <div ref={ref} className="ccd" aria-hidden>
      <DemoFrame>
        <div className="ccd-mini ccd-live">
          <div className="ccd-urlbar">
            <span className="ccd-lights">
              <i />
              <i />
              <i />
            </span>
            <span className="ccd-url">
              <b>capturecat.so</b>/share/7Kq2fX
            </span>
          </div>
          <div className="ccd-share">
            <div className="ccd-player">
              <div className="ccd-player-video" />
              <div className="ccd-player-bar">
                <span className="ccd-play">▶</span>
                <span className="ccd-scrub">
                  <span className="ccd-scrub-fill" />
                  <i className="ccd-scrub-mark" style={{ left: "18%" }} />
                  <i className="ccd-scrub-mark" style={{ left: "36%" }} />
                  <i className="ccd-scrub-mark" style={{ left: "71%" }} />
                </span>
                <span>1:36</span>
              </div>
              <div style={{ fontSize: "calc(15 * var(--u))", fontWeight: 600, marginTop: "calc(4 * var(--u))" }}>
                Launch video
              </div>
              <div style={{ fontSize: "calc(11.5 * var(--u))", color: "rgb(255 255 255 / 0.5)" }}>
                Sam Rivera · 2 days ago · 1,284 views
              </div>
            </div>
            <div className="ccd-comments">
              <h6>Comments · 3</h6>
              {COMMENTS.map((c) => (
                <div key={c.name} className="ccd-comment">
                  <span className="ccd-avatar" />
                  <span>
                    <b>
                      {c.name}
                      <em>{c.time}</em>
                    </b>
                    {c.body}
                  </span>
                </div>
              ))}
            </div>
          </div>
        </div>
      </DemoFrame>
    </div>
  );
}

/** Retention: starts at 100 %, a dip around 0:42, a tail to the end. */
const CURVE =
  "M0,6 C60,8 120,14 180,22 C240,30 330,34 400,40 C430,44 450,64 470,78 C510,94 560,100 620,106 C700,114 780,120 860,128 C920,134 960,138 1000,142";

export function AnalyticsDemo() {
  const ref = useOffscreenPause<HTMLDivElement>();
  return (
    <div ref={ref} className="ccd" aria-hidden>
      <DemoFrame>
        <div className="ccd-mini ccd-live">
          <div className="ccd-urlbar">
            <span className="ccd-lights">
              <i />
              <i />
              <i />
            </span>
            <span className="ccd-url">
              <b>app.capturecat.so</b>/videos/7Kq2fX/analytics
            </span>
          </div>
          <div className="ccd-an" style={{ height: "calc(100% - 44 * var(--u))" }}>
            <div className="ccd-an-stats">
              <div>
                <small>Views</small>
                <b>1,284</b>
              </div>
              <div>
                <small>Watch time</small>
                <b>21h 12m</b>
              </div>
              <div>
                <small>Avg. completion</small>
                <b>64%</b>
              </div>
            </div>
            <div className="ccd-an-chart">
              <svg viewBox="0 0 1000 160" preserveAspectRatio="none">
                <defs>
                  <linearGradient id="ccdRet" x1="0" y1="0" x2="0" y2="1">
                    <stop offset="0" stopColor="#67e8f9" stopOpacity="0.35" />
                    <stop offset="1" stopColor="#67e8f9" stopOpacity="0" />
                  </linearGradient>
                </defs>
                <path d={`${CURVE} L1000,160 L0,160 Z`} fill="url(#ccdRet)" />
                <path d={CURVE} fill="none" stroke="#67e8f9" strokeWidth="2.5" vectorEffect="non-scaling-stroke" />
              </svg>
              <span className="ccd-an-cover" />
              <span className="ccd-an-flag">
                <span>Most viewers leave at 0:42</span>
              </span>
              <span className="ccd-an-axis">
                <span>0:00</span>
                <span>0:24</span>
                <span>0:48</span>
                <span>1:12</span>
                <span>1:36</span>
              </span>
            </div>
          </div>
        </div>
      </DemoFrame>
    </div>
  );
}
