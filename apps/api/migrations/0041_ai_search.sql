-- AI search visibility: the buyer questions CaptureCat wants to be the answer
-- to, rerun against AI engines and Google on a schedule, with each loss
-- diagnosed (missing page, weak page, crawl problem, third-party sources).
-- Admin console → AI search (routes/admin-ai-search.ts, lib/ai-search/*).
--
-- Additive only: new tables, nothing else touched.
--
-- No CHECK constraints on the enum-like columns (engine, kind, status) on
-- purpose, as in 0037: SQLite can't alter a CHECK without rebuilding the
-- table. The API's zod schemas are the gate; the values are persistence
-- identity and are never renamed.

-- 1. The questions. One row = one buyer decision phrased two ways: `prompt`
--    is asked of AI engines word for word, `keyword` is the Google query.
CREATE TABLE IF NOT EXISTS ai_search_questions (
  id           TEXT PRIMARY KEY,
  decision     TEXT NOT NULL,              -- the buyer decision it belongs to (groups the table)
  prompt       TEXT NOT NULL,
  keyword      TEXT NOT NULL,
  branded      INTEGER NOT NULL DEFAULT 0, -- 1 = names CaptureCat; kept out of the non-branded rates
  target_path  TEXT,                       -- our page meant to answer it; NULL = no page yet
  active       INTEGER NOT NULL DEFAULT 1, -- 0 = no longer asked (history kept)
  notes        TEXT NOT NULL DEFAULT '',
  sort         INTEGER NOT NULL DEFAULT 0,
  created_at   TEXT NOT NULL,
  updated_at   TEXT NOT NULL
);

-- 2. Runs: every active question asked of every configured engine.
CREATE TABLE IF NOT EXISTS ai_search_runs (
  id           TEXT PRIMARY KEY,
  kind         TEXT NOT NULL,              -- 'schedule' | 'manual'
  engines      TEXT NOT NULL,              -- JSON array of engine ids asked
  status       TEXT NOT NULL,              -- 'running' | 'done'
  created_at   TEXT NOT NULL,
  finished_at  TEXT,
  created_by   TEXT                        -- user.id for manual runs
);
CREATE INDEX IF NOT EXISTS idx_ai_search_runs_created ON ai_search_runs (created_at DESC);

-- 3. One answer: a question × engine × sample within a run. Rows are inserted
--    'pending' when the run starts and double as the work queue the cron
--    drains (lib/ai-search/runner.ts), so a run survives across invocations.
CREATE TABLE IF NOT EXISTS ai_search_results (
  id           TEXT PRIMARY KEY,
  run_id       TEXT NOT NULL REFERENCES ai_search_runs(id),
  question_id  TEXT NOT NULL REFERENCES ai_search_questions(id),
  engine       TEXT NOT NULL,              -- 'chatgpt' | 'gemini' | 'perplexity' | 'claude' | 'google'
  sample       INTEGER NOT NULL DEFAULT 0, -- AI answers vary; some engines are asked more than once
  prompt       TEXT NOT NULL,              -- exactly what was sent (the question can be edited later)
  status       TEXT NOT NULL,              -- 'pending' | 'running' | 'ok' | 'error'
  attempts     INTEGER NOT NULL DEFAULT 0,
  started_at   TEXT,
  finished_at  TEXT,
  model        TEXT,                       -- model/version the engine reported
  mentioned    INTEGER,                    -- AI: CaptureCat named in the answer. Google: in the AI Overview
  cited        INTEGER,                    -- a capturecat.so URL among the cited sources / AI Overview references
  rank         INTEGER,                    -- AI: CaptureCat's place among products named (1 = first). Google: organic rank
  own_url      TEXT,                       -- our URL that was cited (AI) or ranked (Google)
  brands       TEXT NOT NULL DEFAULT '[]', -- JSON: products named, in order of first mention
  queries      TEXT NOT NULL DEFAULT '[]', -- JSON: web searches the engine ran for this answer
  answer       TEXT NOT NULL DEFAULT '',   -- answer text (Markdown), truncated
  cost_usd     REAL NOT NULL DEFAULT 0,
  error        TEXT
);
CREATE INDEX IF NOT EXISTS idx_ai_search_results_queue ON ai_search_results (status, started_at);
CREATE INDEX IF NOT EXISTS idx_ai_search_results_run ON ai_search_results (run_id, question_id, engine);
CREATE INDEX IF NOT EXISTS idx_ai_search_results_question ON ai_search_results (question_id, engine, finished_at);

-- 4. The sources behind each answer: what an AI engine cited, or Google's
--    organic results (top 20). The raw material for OWN/CLAIM/EARN/CONTEST.
CREATE TABLE IF NOT EXISTS ai_search_result_sources (
  result_id    TEXT NOT NULL REFERENCES ai_search_results(id),
  position     INTEGER NOT NULL,           -- 1-based order in the engine's list
  domain       TEXT NOT NULL,              -- bare host, no www.
  url          TEXT NOT NULL,
  title        TEXT NOT NULL DEFAULT '',
  PRIMARY KEY (result_id, position)
);
CREATE INDEX IF NOT EXISTS idx_ai_search_result_sources_domain ON ai_search_result_sources (domain);

-- 5. What we decided to do about a source. `source_key` is a bare domain
--    ("alternativeto.net") or, for one page, its URL. Unlisted domains get a
--    suggested kind at read time (lib/ai-search/analyze.ts suggestKind).
--    kind: own | claim | earn | contest | competitor | ignore
--    status: todo | doing | done
CREATE TABLE IF NOT EXISTS ai_search_sources (
  source_key   TEXT PRIMARY KEY,
  kind         TEXT NOT NULL,
  status       TEXT NOT NULL DEFAULT 'todo',
  next_step    TEXT NOT NULL DEFAULT '',   -- what to do about it, in a sentence
  url          TEXT,                       -- our listing / profile / reply once it exists
  updated_at   TEXT NOT NULL,
  updated_by   TEXT
);

-- 6. Crawl/index check of every target page, taken when a run starts.
CREATE TABLE IF NOT EXISTS ai_search_page_checks (
  run_id       TEXT NOT NULL REFERENCES ai_search_runs(id),
  path         TEXT NOT NULL,
  checked_at   TEXT NOT NULL,
  http_status  INTEGER,                    -- NULL = the fetch itself failed
  problems     TEXT NOT NULL DEFAULT '[]', -- JSON array of short sentences; [] = healthy
  words        INTEGER,                    -- visible words on the page
  PRIMARY KEY (run_id, path)
);

-- Starter questions (2026-11-09). Edited and extended in the admin console;
-- INSERT OR IGNORE so a re-applied migration never overwrites those edits.
INSERT OR IGNORE INTO ai_search_questions (id, decision, prompt, keyword, branded, target_path, sort, created_at, updated_at) VALUES
  ('mac-best',          'Pick a Mac screen recorder', 'What''s the best screen recorder for Mac right now?', 'best screen recorder for mac', 0, '/best/screen-recorder-for-mac', 10, '2026-11-09T00:00:00.000Z', '2026-11-09T00:00:00.000Z'),
  ('mac-free',          'Pick a Mac screen recorder', 'What''s the best free screen recorder for Mac without a watermark?', 'free screen recorder mac no watermark', 0, '/best/free-screen-recorder-for-mac', 20, '2026-11-09T00:00:00.000Z', '2026-11-09T00:00:00.000Z'),
  ('mac-open-source',   'Pick a Mac screen recorder', 'Is there a good open-source screen recorder for Mac?', 'open source screen recorder mac', 0, '/best/open-source-screen-recorders', 30, '2026-11-09T00:00:00.000Z', '2026-11-09T00:00:00.000Z'),
  ('mac-cheaper',       'Pick a Mac screen recorder', 'What''s a cheaper alternative to subscription Mac screen recorders that zoom in automatically?', 'cheap auto zoom screen recorder mac', 0, '/best/auto-zoom-screen-recorders', 40, '2026-11-09T00:00:00.000Z', '2026-11-09T00:00:00.000Z'),
  ('demo-tool',         'Make product demo videos', 'What''s the best tool for making a product demo video of my app on a Mac?', 'product demo video software mac', 0, '/best/screen-recorder-for-product-demos', 110, '2026-11-09T00:00:00.000Z', '2026-11-09T00:00:00.000Z'),
  ('demo-howto',        'Make product demo videos', 'How do I make a SaaS product demo video that looks professional?', 'how to make a professional product demo video', 0, '/guides/make-a-product-demo-video-on-mac', 120, '2026-11-09T00:00:00.000Z', '2026-11-09T00:00:00.000Z'),
  ('demo-auto-zoom',    'Make product demo videos', 'Which screen recorder automatically zooms in where I click?', 'screen recorder auto zoom on click', 0, '/best/auto-zoom-screen-recorders', 130, '2026-11-09T00:00:00.000Z', '2026-11-09T00:00:00.000Z'),
  ('demo-zoom-effects', 'Make product demo videos', 'How do I add zoom-in effects to a screen recording automatically?', 'add zoom effect to screen recording', 0, '/guides/zoom-in-on-clicks-in-a-screen-recording', 140, '2026-11-09T00:00:00.000Z', '2026-11-09T00:00:00.000Z'),
  ('demo-polish',       'Make product demo videos', 'How do I make my screen recordings look polished, with a nice background and a smooth cursor?', 'make screen recording look professional', 0, '/guides/make-a-screen-recording-look-professional', 150, '2026-11-09T00:00:00.000Z', '2026-11-09T00:00:00.000Z'),
  ('tut-tool',          'Make tutorials and walkthroughs', 'What''s the best screen recorder for making software tutorial videos on Mac?', 'best screen recorder for tutorials mac', 0, '/best/screen-recorder-for-tutorials', 210, '2026-11-09T00:00:00.000Z', '2026-11-09T00:00:00.000Z'),
  ('tut-captions',      'Make tutorials and walkthroughs', 'How do I add captions to a screen recording on Mac?', 'add captions to screen recording mac', 0, '/guides/add-captions-to-a-screen-recording-on-mac', 220, '2026-11-09T00:00:00.000Z', '2026-11-09T00:00:00.000Z'),
  ('tut-blur',          'Make tutorials and walkthroughs', 'How can I blur passwords or private info in a screen recording?', 'blur sensitive information screen recording', 0, '/guides/blur-sensitive-information-in-a-screen-recording', 230, '2026-11-09T00:00:00.000Z', '2026-11-09T00:00:00.000Z'),
  ('tut-keystrokes',    'Make tutorials and walkthroughs', 'How do I show the keys I press on screen while recording on Mac?', 'show keystrokes screen recording mac', 0, '/guides/show-keyboard-shortcuts-in-a-screen-recording', 240, '2026-11-09T00:00:00.000Z', '2026-11-09T00:00:00.000Z'),
  ('tut-cursor',        'Make tutorials and walkthroughs', 'How do I smooth out a shaky cursor in a screen recording?', 'smooth cursor screen recording', 0, '/guides/smooth-cursor-in-a-screen-recording', 250, '2026-11-09T00:00:00.000Z', '2026-11-09T00:00:00.000Z'),
  ('tut-system-audio',  'Make tutorials and walkthroughs', 'How do I record my Mac screen with system audio?', 'record mac screen with system audio', 0, '/guides/record-mac-screen-with-system-audio', 260, '2026-11-09T00:00:00.000Z', '2026-11-09T00:00:00.000Z'),
  ('tut-webcam',        'Make tutorials and walkthroughs', 'How do I record my screen and webcam at the same time on a Mac?', 'record screen and webcam mac', 0, '/guides/record-screen-and-webcam-on-mac', 270, '2026-11-09T00:00:00.000Z', '2026-11-09T00:00:00.000Z'),
  ('share-analytics',   'Share recordings with a team', 'What''s the best way to send a screen recording as a link and see who watched it?', 'share screen recording link with analytics', 0, '/guides/share-a-screen-recording-link-with-analytics', 310, '2026-11-09T00:00:00.000Z', '2026-11-09T00:00:00.000Z'),
  ('share-async',       'Share recordings with a team', 'What''s a good async video tool for sending screen recordings to my team?', 'async video messaging tool', 0, '/best/loom-alternatives', 320, '2026-11-09T00:00:00.000Z', '2026-11-09T00:00:00.000Z'),
  ('agent-mcp',         'Automate with AI agents', 'Is there a screen recorder that AI agents like Claude or Cursor can control?', 'screen recorder mcp server', 0, '/best/screen-recorders-for-ai-agents', 410, '2026-11-09T00:00:00.000Z', '2026-11-09T00:00:00.000Z'),
  ('agent-edit',        'Automate with AI agents', 'Can an AI agent edit my screen recordings for me?', 'edit screen recording with ai', 0, '/guides/edit-a-screen-recording-with-an-ai-agent', 420, '2026-11-09T00:00:00.000Z', '2026-11-09T00:00:00.000Z'),
  ('other-windows',     'Record outside the Mac', 'What''s the best screen recorder for Windows that zooms in automatically?', 'auto zoom screen recorder windows', 0, '/best/screen-recorder-for-windows', 510, '2026-11-09T00:00:00.000Z', '2026-11-09T00:00:00.000Z'),
  ('other-browser',     'Record outside the Mac', 'How can I record and edit my screen on Linux or a Chromebook in the browser?', 'screen recorder chromebook linux browser', 0, '/guides/record-your-screen-on-windows-linux-or-chromebook', 520, '2026-11-09T00:00:00.000Z', '2026-11-09T00:00:00.000Z'),
  ('other-iphone',      'Record outside the Mac', 'How do I record my iPhone screen on a Mac for an app demo?', 'record iphone screen on mac', 0, '/guides/record-iphone-screen-on-mac', 530, '2026-11-09T00:00:00.000Z', '2026-11-09T00:00:00.000Z'),
  ('social-vertical',   'Repurpose for social and docs', 'How do I turn a horizontal screen recording into a vertical video for TikTok or Shorts?', 'convert screen recording to vertical video', 0, '/guides/make-a-vertical-video-from-a-screen-recording', 610, '2026-11-09T00:00:00.000Z', '2026-11-09T00:00:00.000Z'),
  ('social-gif',        'Repurpose for social and docs', 'How do I record a short demo GIF for a GitHub README on Mac?', 'record gif mac github readme', 0, '/docs/export-and-sharing/gif', 620, '2026-11-09T00:00:00.000Z', '2026-11-09T00:00:00.000Z'),
  ('social-full-page',  'Repurpose for social and docs', 'How do I record a scrolling full-page website video?', 'record full page website scrolling video', 0, '/guides/record-a-full-page-website-video', 630, '2026-11-09T00:00:00.000Z', '2026-11-09T00:00:00.000Z'),
  ('brand-what',        'Evaluate CaptureCat', 'What is CaptureCat and is it any good?', 'capturecat', 1, '/', 910, '2026-11-09T00:00:00.000Z', '2026-11-09T00:00:00.000Z'),
  ('brand-pricing',     'Evaluate CaptureCat', 'Is CaptureCat free, and what do you get on the paid plan?', 'capturecat pricing', 1, '/pricing', 920, '2026-11-09T00:00:00.000Z', '2026-11-09T00:00:00.000Z'),
  ('brand-windows',     'Evaluate CaptureCat', 'Does CaptureCat work on Windows?', 'capturecat windows', 1, '/docs/web-app/mac-and-web', 930, '2026-11-09T00:00:00.000Z', '2026-11-09T00:00:00.000Z');

-- First-pass source decisions (2026-11-09), from a manual sweep of the
-- questions' search results: none of these lists CaptureCat yet. Edited in
-- the admin console from here on; INSERT OR IGNORE never overwrites that.
INSERT OR IGNORE INTO ai_search_sources (source_key, kind, status, next_step, updated_at) VALUES
  ('alternativeto.net', 'claim', 'todo', 'Create the CaptureCat listing: Mac app plus the browser app (Windows, Linux, ChromeOS), AGPL-3.0, free for personal use; mark the auto-zoom recorders it replaces. It appears in the results for four or more of our questions.', '2026-11-09T00:00:00.000Z'),
  ('producthunt.com', 'claim', 'todo', 'Create the product page and plan a launch; the auto-zoom competitors all have one.', '2026-11-09T00:00:00.000Z'),
  ('openalternative.co', 'claim', 'todo', 'Submit CaptureCat as an open-source (AGPL-3.0) screen recorder; it ranks for the open-source question.', '2026-11-09T00:00:00.000Z'),
  ('saashub.com', 'claim', 'todo', 'Submit the listing.', '2026-11-09T00:00:00.000Z'),
  ('macupdate.com', 'claim', 'todo', 'Submit the Mac app.', '2026-11-09T00:00:00.000Z'),
  ('formulae.brew.sh', 'claim', 'todo', 'Open a Homebrew cask PR (signed and notarized; auto_updates true, it updates itself).', '2026-11-09T00:00:00.000Z'),
  ('glama.ai', 'claim', 'todo', 'List the CaptureCat MCP server. MCP directories fill most of the screen-recorder-MCP results, and CaptureCat is in none of them.', '2026-11-09T00:00:00.000Z'),
  ('mcpservers.org', 'claim', 'todo', 'List the CaptureCat MCP server.', '2026-11-09T00:00:00.000Z'),
  ('lobehub.com', 'claim', 'todo', 'List the CaptureCat MCP server.', '2026-11-09T00:00:00.000Z'),
  ('github.com', 'earn', 'todo', 'Pull requests to awesome-mac (jaywcjlove) and open-source-mac-os-apps (serhii-londar), Video / Screen Recording sections; both list other open-source auto-zoom recorders but not CaptureCat.', '2026-11-09T00:00:00.000Z'),
  ('https://github.com/capturecat-dev/capturecat', 'own', 'todo', 'Fix the repo''s About text and topics: it reads as Mac-only and aggregators copy it. Mention the browser app (Windows, Linux, ChromeOS), MCP and captions.', '2026-11-09T00:00:00.000Z'),
  ('reddit.com', 'earn', 'todo', 'r/macapps first (recurring threads asking for open-source and auto-zoom recorders), then r/SideProject and r/SaaS for demo makers. Reply where CaptureCat fits, with disclosure; never post everywhere.', '2026-11-09T00:00:00.000Z'),
  ('news.ycombinator.com', 'earn', 'todo', 'Show HN with a release worth showing.', '2026-11-09T00:00:00.000Z');
