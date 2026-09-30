#!/usr/bin/env bash
# One-time Cloudflare for SaaS setup for custom share domains.
#
# What it does (idempotent — safe to re-run):
#   1. Creates the originless, proxied AAAA record for the CNAME target
#      (customers.capturecat.so → 100::). Customers CNAME to this name.
#   2. Sets it as the zone's SaaS fallback origin.
#
# It deliberately does NOT add a zone-wide `*/*` Workers route. It used to
# (bound to the web Worker), and on 2026-09-30 that route took
# api.capturecat.so and admin.capturecat.so down with Cloudflare 1019: the
# `*/*` route to capturecat-start collided with their Workers Custom Domains.
# A `*/*` route on a zone that also hosts other Workers is a recursion hazard,
# so it must never be created by a script. Routing customer hostnames to the
# web Worker needs a design verified on a non-production zone first; until
# then custom share domains stay off (0 rows in custom_domains that day).
#
# Needs: CF_API_TOKEN with Zone:DNS:Edit and Zone:SSL and Certificates:Edit
#        on the capturecat.so zone; CF_ZONE_ID.
# Then:  cd apps/api && npx wrangler secret put CF_SAAS_API_TOKEN
#        (a token with SSL and Certificates:Edit is enough for the Worker)
#        and set CF_ZONE_ID in wrangler.toml [vars].
set -euo pipefail

: "${CF_API_TOKEN:?set CF_API_TOKEN}"
: "${CF_ZONE_ID:?set CF_ZONE_ID}"
TARGET="${CUSTOM_DOMAIN_CNAME_TARGET:-customers.capturecat.so}"
API="https://api.cloudflare.com/client/v4"
auth=(-H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json")

# Refuse to run on a zone where a catch-all route already exists: it is the
# 1019 outage above waiting to happen.
if curl -fsS "${auth[@]}" "$API/zones/$CF_ZONE_ID/workers/routes" \
  | jq -e '.result[] | select(.pattern=="*/*")' >/dev/null; then
  echo "ERROR: a */* Workers route exists on this zone. It hijacks every other"
  echo "Worker's hostname (api., admin.) — delete it before going further." >&2
  exit 1
fi

echo "→ 1/2 originless AAAA record for $TARGET"
existing=$(curl -fsS "${auth[@]}" "$API/zones/$CF_ZONE_ID/dns_records?type=AAAA&name=$TARGET" | jq -r '.result[0].id // empty')
if [ -z "$existing" ]; then
  curl -fsS "${auth[@]}" -X POST "$API/zones/$CF_ZONE_ID/dns_records" \
    --data "{\"type\":\"AAAA\",\"name\":\"$TARGET\",\"content\":\"100::\",\"proxied\":true,\"comment\":\"Cloudflare for SaaS CNAME target (originless)\"}" | jq -r '.success'
else
  echo "  exists ($existing)"
fi

echo "→ 2/2 fallback origin"
curl -fsS "${auth[@]}" -X PUT "$API/zones/$CF_ZONE_ID/custom_hostnames/fallback_origin" \
  --data "{\"origin\":\"$TARGET\"}" | jq -r '.result.status // .errors'

echo
echo "Done. Verify in the dashboard: SSL/TLS → Custom Hostnames shows fallback origin Active."
echo "Customers point: CNAME share.theirdomain.com → $TARGET"
