-- Viewer analytics are a Pro feature (2026-11-02): the terms and pricing
-- say Free has none, but GET /video/:id/analytics only checked ownership —
-- harmless while Free had no share links, not once 0039 gave it some.
--
-- Plan feature flag (lib/plans.ts FEATURE_KEYS):
--   viewerAnalytics  plays, completions, watch heatmap, drop-off, clicks,
--                    countries and referrers for a shared video
--                    (routes/analytics.ts, MCP get_video_analytics).
-- Deny by default: a row without the key has none. Views keep being
-- recorded on every plan, so upgrading shows the history.
UPDATE plan
   SET features = json_set(features, '$.viewerAnalytics', json('true')),
       updated_at = datetime('now')
 WHERE name IN ('pro', 'business') AND json_valid(features);
UPDATE plan
   SET features = json_set(features, '$.viewerAnalytics', json('false')),
       updated_at = datetime('now')
 WHERE name = 'free' AND json_valid(features);
