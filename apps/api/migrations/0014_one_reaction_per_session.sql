-- One reaction per viewer per video. Sessions are anonymous browser ids, so
-- this is "one like per user" at the strength anonymity allows.

-- Dedupe first (keep each session's newest reaction), or the unique index
-- cannot build on existing data.
DELETE FROM video_reactions
 WHERE reaction_id NOT IN (
   SELECT reaction_id FROM (
     SELECT reaction_id, ROW_NUMBER() OVER (
       PARTITION BY video_id, session_id ORDER BY created_at DESC
     ) AS rn FROM video_reactions
   ) WHERE rn = 1
 );

CREATE UNIQUE INDEX IF NOT EXISTS idx_video_reactions_session
  ON video_reactions (video_id, session_id);
