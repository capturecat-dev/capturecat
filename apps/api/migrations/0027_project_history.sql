-- Cloud-project history (docs/project-history.md; design 2026-09-30).
--
-- A REVISION is still the CAS counter of PUT /cloud-projects/:id/project
-- (If-Match, one per save). A VERSION is a retained checkpoint: one row here
-- plus a full gzipped snapshot of project.json in R2 (no diff chains), plus
-- the media manifest it was saved against. A save EXTENDS the head version
-- (coalescing: same actor + client + source, head unnamed `edit`, opened
-- < 10 min and updated < 3 min ago, no checkpoint) or opens a new one — in the
-- SAME D1 batch as the revision CAS, every version statement guarded on the
-- CAS having landed, so a lost race writes no version row.
--
-- MEDIA RETENTION: manifests are content-addressed (manifest_sha = SHA-256 of
-- the canonical file list). Every version pins its manifest's objects:
-- deleteObjectIfUnreferenced and the stage/finalize credit both check
-- `cloud_project_manifest_objects ⋈ cloud_project_versions` with NOT EXISTS —
-- reference counts are derived, never stored. Pinned media stays a `ready`
-- object, so STORAGE_SUM_SQL (lib/db.ts) already counts it (owner decision 3).
-- Version DOCUMENTS are not counted against storage; they are bounded by
-- 1000 versions and 256 MB of snapshots per project (lib/project-history.ts).
--
-- BACKFILL IS LAZY: existing projects get their first (`upload`) version on
-- their first save or history read after this migration. Nothing here touches
-- existing rows beyond adding nullable / defaulted columns, so it is safe on
-- live data and the previous Worker keeps working against the new schema.
--
-- Apply BEFORE deploying the Worker that reads these tables.

CREATE TABLE IF NOT EXISTS cloud_project_versions (
  id                   TEXT PRIMARY KEY,
  project_id           TEXT NOT NULL REFERENCES cloud_projects (id) ON DELETE CASCADE,
  seq                  INTEGER NOT NULL,             -- 1, 2, 3… per project (cloud_projects.next_version_seq)
  first_revision       INTEGER NOT NULL,             -- the revision that opened it
  revision             INTEGER NOT NULL,             -- the revision it holds (its last save)
  doc_r2_key           TEXT NOT NULL,                -- snapshot object (gzip when customMetadata.enc = "gzip")
  doc_bytes            INTEGER NOT NULL,             -- project.json bytes (uncompressed)
  stored_bytes         INTEGER NOT NULL,             -- bytes in R2 (what the 256 MB cap sums)
  doc_sha256           TEXT NOT NULL,                -- of the uncompressed bytes
  manifest_sha         TEXT,                         -- media manifest at save time; NULL = no media
  kind                 TEXT NOT NULL,                -- 'upload' | 'edit' | 'merge' | 'restore'
  label                TEXT,                         -- named version (exempt from the day window)
  named_by             TEXT,
  named_at             TEXT,
  actor_uid            TEXT,                         -- who saved (owner or org member)
  client_kind          TEXT NOT NULL DEFAULT 'unknown', -- 'mac' | 'web' | 'unknown'
  client_id            TEXT,
  source               TEXT NOT NULL DEFAULT 'human',   -- 'human' | 'agent' | 'mixed'
  change_json          TEXT,                         -- canonical change-set (≤ 32 KB); NULL = unknown
  restored_from        TEXT,                         -- version id a restore copied
  merged_from_revision INTEGER,                      -- X-CC-Merged-From
  opened_at            TEXT NOT NULL,
  updated_at           TEXT NOT NULL,
  UNIQUE (project_id, seq)
);
CREATE INDEX IF NOT EXISTS idx_cloud_project_versions_seq ON cloud_project_versions (project_id, seq DESC);
CREATE INDEX IF NOT EXISTS idx_cloud_project_versions_revision ON cloud_project_versions (project_id, revision);
CREATE INDEX IF NOT EXISTS idx_cloud_project_versions_manifest ON cloud_project_versions (project_id, manifest_sha);
CREATE INDEX IF NOT EXISTS idx_cloud_project_versions_unnamed ON cloud_project_versions (updated_at) WHERE label IS NULL;

-- A committed file set, content-addressed within the project.
CREATE TABLE IF NOT EXISTS cloud_project_manifests (
  project_id   TEXT NOT NULL REFERENCES cloud_projects (id) ON DELETE CASCADE,
  manifest_sha TEXT NOT NULL,
  files_json   TEXT NOT NULL,                        -- lib/project-history.ts manifestText()
  created_at   TEXT NOT NULL,
  PRIMARY KEY (project_id, manifest_sha)
);

-- The objects a manifest references (one row per distinct SHA-256).
CREATE TABLE IF NOT EXISTS cloud_project_manifest_objects (
  project_id   TEXT NOT NULL,
  manifest_sha TEXT NOT NULL,
  sha256       TEXT NOT NULL,
  PRIMARY KEY (project_id, manifest_sha, sha256),
  FOREIGN KEY (project_id, manifest_sha)
    REFERENCES cloud_project_manifests (project_id, manifest_sha) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_cloud_project_manifest_objects_sha ON cloud_project_manifest_objects (project_id, sha256);

ALTER TABLE cloud_projects ADD COLUMN head_version_id TEXT;
ALTER TABLE cloud_projects ADD COLUMN next_version_seq INTEGER NOT NULL DEFAULT 1;
ALTER TABLE cloud_projects ADD COLUMN manifest_sha TEXT;           -- the committed file set's manifest
ALTER TABLE cloud_projects ADD COLUMN last_checkpoint_at TEXT;     -- X-CC-Checkpoint throttle (1/min)
ALTER TABLE cloud_projects ADD COLUMN history_swept_at TEXT;       -- hourly retention sweep cursor
CREATE INDEX IF NOT EXISTS idx_cloud_projects_history_sweep ON cloud_projects (history_swept_at);

-- Plan limits (lib/plans.ts LIMIT_KEYS). A missing key reads as 0 = no
-- cloud history, so Free (and any row this does not touch) gets none.
UPDATE plan SET limits = json_set(limits, '$.maxHistoryDays', 30, '$.maxNamedVersions', 25),
                updated_at = datetime('now')
WHERE name = 'pro';
UPDATE plan SET limits = json_set(limits, '$.maxHistoryDays', 365, '$.maxNamedVersions', 500),
                updated_at = datetime('now')
WHERE name = 'business';
UPDATE plan SET limits = json_set(limits, '$.maxHistoryDays', 0, '$.maxNamedVersions', 0),
                updated_at = datetime('now')
WHERE name = 'free';
