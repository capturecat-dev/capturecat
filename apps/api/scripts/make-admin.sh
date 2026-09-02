#!/usr/bin/env bash
set -euo pipefail

# Promote a user to admin.
#
#   ./scripts/make-admin.sh you@example.com [--local|--remote]
#
# ORDERING MATTERS. Better Auth creates the `user` row on FIRST SIGN-IN, so the
# row does not exist until the account has signed in at least once. Run this
# before that and it updates zero rows — it says so rather than pretending.
#
# Inserting the row by hand first is tempting and is a trap: the social sign-in
# then has to reconcile an existing email against a fresh OAuth account, which
# depends on account-linking config and can leave you with two users or none.

EMAIL="${1:-}"
MODE="${2:---remote}"
if [[ -z "$EMAIL" ]]; then
  echo "usage: $0 <email> [--local|--remote]" >&2
  exit 1
fi
SAFE="${EMAIL//\'/\'\'}"

cd "$(dirname "$0")/.."

count() {
  npx wrangler d1 execute capturecat "$MODE" --json \
    --command "SELECT COUNT(*) AS n FROM user WHERE email = '$SAFE'" 2>/dev/null \
    | python3 -c "import json,sys; print(json.load(sys.stdin)[0]['results'][0]['n'])" 2>/dev/null || echo 0
}

if [[ "$(count)" == "0" ]]; then
  echo "No user with email '$EMAIL' exists yet."
  echo "Sign in once with that account, then run this again."
  exit 1
fi

npx wrangler d1 execute capturecat "$MODE" \
  --command "UPDATE user SET role = 'admin' WHERE email = '$SAFE'" >/dev/null

npx wrangler d1 execute capturecat "$MODE" --json \
  --command "SELECT email, role FROM user WHERE email = '$SAFE'" 2>/dev/null \
  | python3 -c "
import json,sys
for u in json.load(sys.stdin)[0]['results']:
    print(f\"  {u['email']} -> role={u['role']}\")"
echo "Admin is re-read from D1 on every request, so this takes effect immediately."
