-- Free is for personal use; commercial use needs a paid plan (Cap-style
-- pricing, 2026-10-29). There is no separate licence product: Pro (and
-- Business) is what commercial use needs.
--
-- 1. Plan feature flag (lib/plans.ts FEATURE_KEYS):
--      commercialUse  Commercial use, and recordings of any length. Without
--                     it the Mac and web recorders stop each recording at
--                     FREE_RECORDING_SECONDS (5 min). The cap is enforced in
--                     the clients — no-account and offline Mac users need it
--                     too — and they read this flag from GET /api/me.
--    A plan row without the key reads it as FALSE (deny by default), so a row
--    this does not touch is capped. Paid rows get it; Free does not. Rows whose
--    JSON is unreadable already deny everything and are left alone.
UPDATE plan
   SET features = json_set(features, '$.commercialUse', json('true')),
       updated_at = datetime('now')
 WHERE name IN ('pro', 'business') AND json_valid(features);
UPDATE plan
   SET features = json_set(features, '$.commercialUse', json('false')),
       updated_at = datetime('now')
 WHERE name = 'free' AND json_valid(features);

-- 2. A small cloud allowance on Free, so the web recorder (which saves every
--    take as a cloud project) and short share links work without Pro: 2 GiB
--    in total, 1 GiB per file, 10 new shares a day, shares up to 5 minutes
--    (maxDurationSeconds, already 300). All editable in the admin console.
UPDATE plan
   SET features = json_set(features, '$.cloudShare', json('true')),
       limits = json_set(
         limits,
         '$.maxTotalStorageBytes', 2147483648,
         '$.maxFileSizeBytes', 1073741824,
         '$.maxUploadsPerDay', 10,
         '$.maxDurationSeconds', 300
       ),
       description = 'Personal use. Recordings up to 5 minutes.',
       updated_at = datetime('now')
 WHERE name = 'free' AND json_valid(features) AND json_valid(limits);
