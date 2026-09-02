-- Feature flags for Teams + SSO. Deny-by-default lives in code
-- (FEATURE_DEFAULTS); Pro gains teams so paid users get the team library
-- immediately. SSO stays off everywhere until a Business plan exists —
-- the admin console can flip it per plan without a deploy.
UPDATE plan SET features = json_set(features, '$.teams', json('true'))
 WHERE name = 'pro';
UPDATE plan SET features = json_set(features, '$.teams', json('false'), '$.sso', json('false'))
 WHERE name = 'free';
