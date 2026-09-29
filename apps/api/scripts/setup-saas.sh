#!/usr/bin/env bash
# One-time Cloudflare for SaaS setup for custom share domains.
#
# What it does (idempotent — safe to re-run):
#   1. Creates the originless, proxied AAAA record for the CNAME target
#      (customers.capturecat.so → 100::). Customers CNAME to this name.
#   2. Sets it as the zone's SaaS fallback origin.
#   3. Adds the `*/*` Workers route on the zone bound to the web Worker, which
#      is the only route pattern Cloudflare matches for custom hostnames.
#      The web Worker passes api./admin. traffic straight through (src/server.ts).
#
# Needs: CF_API_TOKEN with Zone:DNS:Edit, Zone:SSL and Certificates:Edit,
#        Zone:Workers Routes:Edit on the capturecat.so zone; CF_ZONE_ID.
# Then:  cd apps/api && npx wrangler secret put CF_SAAS_API_TOKEN
#        (a token with SSL and Certificates:Edit is enough for the Worker)
#        and set CF_ZONE_ID in wrangler.toml [vars].
set -euo pipefail

: "${CF_API_TOKEN:?set CF_API_TOKEN}"
: "${CF_ZONE_ID:?set CF_ZONE_ID}"
TARGET="${CUSTOM_DOMAIN_CNAME_TARGET:-customers.capturecat.so}"
WEB_WORKER="${WEB_WORKER:-capturecat-start}"
API="https://api.cloudflare.com/client/v4"
auth=(-H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json")

echo "→ 1/3 originless AAAA record for $TARGET"
existing=$(curl -fsS "${auth[@]}" "$API/zones/$CF_ZONE_ID/dns_records?type=AAAA&name=$TARGET" | jq -r '.result[0].id // empty')
if [ -z "$existing" ]; then
  curl -fsS "${auth[@]}" -X POST "$API/zones/$CF_ZONE_ID/dns_records" \
    --data "{\"type\":\"AAAA\",\"name\":\"$TARGET\",\"content\":\"100::\",\"proxied\":true,\"comment\":\"Cloudflare for SaaS CNAME target (originless)\"}" | jq -r '.success'
else
  echo "  exists ($existing)"
fi

echo "→ 2/3 fallback origin"
curl -fsS "${auth[@]}" -X PUT "$API/zones/$CF_ZONE_ID/custom_hostnames/fallback_origin" \
  --data "{\"origin\":\"$TARGET\"}" | jq -r '.result.status // .errors'

echo "→ 3/3 Workers route */* → $WEB_WORKER"
route=$(curl -fsS "${auth[@]}" "$API/zones/$CF_ZONE_ID/workers/routes" | jq -r '.result[] | select(.pattern=="*/*") | .id // empty')
if [ -z "$route" ]; then
  curl -fsS "${auth[@]}" -X POST "$API/zones/$CF_ZONE_ID/workers/routes" \
    --data "{\"pattern\":\"*/*\",\"script\":\"$WEB_WORKER\"}" | jq -r '.success'
else
  echo "  exists ($route)"
fi

echo
echo "Done. Verify in the dashboard: SSL/TLS → Custom Hostnames shows fallback origin Active."
echo "Customers point: CNAME share.theirdomain.com → $TARGET"
