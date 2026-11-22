-- Better Auth 1.7 (@better-auth/sso): name each SAML provider's IdP explicitly.
--
-- 1.6 used the provider's top-level `issuer` as the IdP entity ID. 1.7 treats
-- `issuer` as the SERVICE provider only, and refuses to build the IdP for a
-- manually configured SAML provider (no metadata XML) unless
-- `samlConfig.idpMetadata.entityID` is set: "SAML manual IdP configuration
-- requires idpMetadata.entityID". Without this backfill every SAML provider
-- registered before the upgrade stops signing anyone in.
--
-- Every SAML row here came from the Team page (apps/web trpc `registerSaml`),
-- which stored the IdP's entity ID as `issuer` — so `issuer` is exactly the
-- value 1.7 wants. Rows that already carry IdP metadata XML or an entity ID,
-- OIDC rows, and malformed JSON are left alone. Idempotent.
--
-- Apply BEFORE deploying the 1.7 API (it is harmless to 1.6, which ignores
-- the extra key).

UPDATE "ssoProvider"
   SET "samlConfig" = json_set(
         "samlConfig",
         '$.idpMetadata',
         json_set(COALESCE(json_extract("samlConfig", '$.idpMetadata'), '{}'), '$.entityID', "issuer")
       )
 WHERE "samlConfig" IS NOT NULL
   AND json_valid("samlConfig")
   AND json_extract("samlConfig", '$.idpMetadata.metadata') IS NULL
   AND json_extract("samlConfig", '$.idpMetadata.entityID') IS NULL;
