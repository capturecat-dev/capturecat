-- Cloud projects for the web editor (app.capturecat.so/editor).
--
-- The Mac app uploads a project bundle ("Open in Web Editor"); the web editor
-- loads it through short-lived presigned GETs and saves project.json back with
-- optimistic concurrency; the Mac can pull the web's edits. Routes live in
-- src/routes/cloud-projects.ts, the rules in src/lib/cloud-projects.ts.
--
-- WHERE project.json LIVES: R2, not D1. D1 caps any single value/row at 2 MB,
-- and project.json is unbounded — it grows with the recording (word-timed
-- subtitles, annotations, regions), so a long take can cross that line and a
-- D1 column would start refusing saves of perfectly valid projects. In R2 the
-- document is one object per save attempt (`…/doc/<revision>-<nonce>.json`):
-- a save writes its new object first and only then compare-and-swaps the row
-- (`WHERE revision = ?`), so a lost race or a crash never leaves the row
-- pointing at a torn document (the nonce keeps two racing saves of the same
-- revision from writing the same key). D1 keeps only the small metadata, which keeps
-- the project list a cheap indexed read.
--
-- STORAGE: every ready object and every document counts against the owner's
-- plan quota — STORAGE_SUM_SQL in src/lib/db.ts sums these tables alongside
-- shared videos and stored screenshots (migration 0025). That SQL references
-- the tables below, so this migration MUST be applied before the Worker that
-- reads them is deployed.

CREATE TABLE IF NOT EXISTS cloud_projects (
  id              TEXT PRIMARY KEY,                 -- the Mac project UUID, uppercase canonical form
  owner_uid       TEXT NOT NULL,                    -- Better Auth user.id; the ONLY writer
  org_id          TEXT,                             -- NULL = personal; set = that org's members may READ
  name            TEXT NOT NULL,
  revision        INTEGER NOT NULL DEFAULT 0,       -- project.json revision; 0 = no document saved yet
  doc_r2_key      TEXT,                             -- R2 object holding project.json at `revision`
  doc_bytes       INTEGER NOT NULL DEFAULT 0,
  doc_sha256      TEXT,
  total_bytes     INTEGER NOT NULL DEFAULT 0,       -- committed media + document (listing only)
  staged_manifest TEXT,                             -- last PUT manifest (JSON), committed by /finalize
  staged_at       TEXT,
  created_at      TEXT NOT NULL,
  updated_at      TEXT NOT NULL,
  updated_by      TEXT                              -- uid of the last document save
);
CREATE INDEX IF NOT EXISTS idx_cloud_projects_owner ON cloud_projects (owner_uid, updated_at);
CREATE INDEX IF NOT EXISTS idx_cloud_projects_org ON cloud_projects (org_id, updated_at);

-- Stored R2 objects, content-addressed WITHIN a project: one row per distinct
-- SHA-256, however many logical paths point at it. `pending` = presigned,
-- bytes not yet verified (never counted, swept after 2 h); `ready` = size AND
-- SHA-256 verified server-side at /finalize (counted against the quota).
CREATE TABLE IF NOT EXISTS cloud_project_objects (
  project_id   TEXT NOT NULL REFERENCES cloud_projects (id) ON DELETE CASCADE,
  sha256       TEXT NOT NULL,                       -- lowercase hex
  owner_uid    TEXT NOT NULL,                       -- denormalized for the storage sum
  bytes        INTEGER NOT NULL,
  content_type TEXT NOT NULL,
  r2_key       TEXT NOT NULL UNIQUE,
  status       TEXT NOT NULL DEFAULT 'pending',     -- 'pending' | 'ready'
  etag         TEXT,
  created_at   TEXT NOT NULL,
  uploaded_at  TEXT,
  PRIMARY KEY (project_id, sha256)
);
CREATE INDEX IF NOT EXISTS idx_cloud_project_objects_owner ON cloud_project_objects (owner_uid, status);
CREATE INDEX IF NOT EXISTS idx_cloud_project_objects_status ON cloud_project_objects (status, created_at);

-- The committed file set: logical path (relative to the Mac project folder,
-- e.g. `recording.mov`, `cursor.json`, `voiceover-<uuid>.m4a`) → object.
-- Replaced wholesale by /finalize; only ever points at `ready` objects.
CREATE TABLE IF NOT EXISTS cloud_project_files (
  project_id   TEXT NOT NULL REFERENCES cloud_projects (id) ON DELETE CASCADE,
  path         TEXT NOT NULL,
  sha256       TEXT NOT NULL,
  bytes        INTEGER NOT NULL,
  content_type TEXT NOT NULL,
  r2_key       TEXT NOT NULL,
  source       TEXT,                                -- the exact reference string in project.json when it is
                                                    -- not simply `path` (e.g. an absolute backgroundImagePath)
  uploaded_at  TEXT NOT NULL,
  PRIMARY KEY (project_id, path)
);
CREATE INDEX IF NOT EXISTS idx_cloud_project_files_sha ON cloud_project_files (project_id, sha256);
