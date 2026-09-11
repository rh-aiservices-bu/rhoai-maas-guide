#!/usr/bin/env bash
# Set up the subscription priority demo.
#
# Creates two Keycloak groups and two users who belong to BOTH of them, then
# applies three subscriptions:
#
#   quota-standard-tier    group quota-standard   10000 tokens/hour  priority 30
#   quota-bulk-tier        group quota-bulk       20000 tokens/hour  priority 20
#   quota-individual-tier  user  capped-user       5000 tokens/hour  priority 50
#
# Prerequisite: the OIDC demo, which imports the `maas` realm and points MaaS at
# it. This script checks for it and runs it if it is missing.
#
# Idempotent - safe to re-run.
#
# Usage:  ./setup-demo.sh
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REALM=maas
declare -a KC_GROUPS=("quota-standard" "quota-bulk")
declare -a USERS=("dual-user" "capped-user")

oc whoami >/dev/null 2>&1 || { echo "not logged in to a cluster"; exit 1; }

# --- prerequisites ----------------------------------------------------------
echo "==> Prerequisites"

if [ "$(oc get maasmodelref facebook-opt-125m-simulated -n llm \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" != "True" ]; then
  echo "   the simulator model is not Ready."
  echo "   From the repository root: ./scripts/setup-maas.sh --model simulator"
  exit 1
fi
echo "   model facebook-opt-125m-simulated is Ready"

ISSUER=$(oc get aitenants.maas.opendatahub.io models-as-a-service -n ai-tenants \
         -o jsonpath='{.spec.oidc.issuerUrl}' 2>/dev/null)
if [ -z "$ISSUER" ]; then
  echo "   MaaS has no OIDC issuer configured - running the OIDC demo setup first"
  "${DIR}/../oidc-authentication/setup-oidc-demo.sh" || {
    echo "   OIDC setup failed; run demo/oidc-authentication/setup-oidc-demo.sh by hand"; exit 1; }
  ISSUER=$(oc get aitenants.maas.opendatahub.io models-as-a-service -n ai-tenants \
           -o jsonpath='{.spec.oidc.issuerUrl}' 2>/dev/null)
  [ -n "$ISSUER" ] || { echo "   still no issuer configured"; exit 1; }
fi
echo "   OIDC issuer: ${ISSUER}"

# --- locate Keycloak and its bootstrap admin --------------------------------
KC_NS=$(oc get keycloakrealmimport -A -o jsonpath="{range .items[?(@.spec.realm.realm=='${REALM}')]}{.metadata.namespace}{end}" 2>/dev/null)
[ -z "$KC_NS" ] && KC_NS=$(oc get keycloak -A -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null)
[ -z "$KC_NS" ] && { echo "no Keycloak found"; exit 1; }
KC_HOST=$(oc get keycloak -n "$KC_NS" -o jsonpath='{.items[0].spec.hostname.hostname}' 2>/dev/null)
[ -z "$KC_HOST" ] && KC_HOST=$(oc get route -n "$KC_NS" -o jsonpath='{.items[0].spec.host}')
KC="https://${KC_HOST}"
echo "==> Keycloak ${KC_NS} at ${KC}"

ADMIN_USER=$(oc get secret keycloak-initial-admin -n "$KC_NS" -o jsonpath='{.data.username}' 2>/dev/null | base64 -d)
ADMIN_PASS=$(oc get secret keycloak-initial-admin -n "$KC_NS" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)
[ -z "$ADMIN_PASS" ] && { echo "could not read the keycloak-initial-admin secret in ${KC_NS}"; exit 1; }

AT=$(curl -sSk -X POST "${KC}/realms/master/protocol/openid-connect/token" \
  -d grant_type=password -d client_id=admin-cli \
  -d "username=${ADMIN_USER}" -d "password=${ADMIN_PASS}" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin).get("access_token",""))')
[ -n "$AT" ] || { echo "could not obtain a Keycloak admin token"; exit 1; }

api() { curl -sSk -H "Authorization: Bearer ${AT}" -H 'Content-Type: application/json' "$@"; }

# --- groups -----------------------------------------------------------------
echo "==> Groups"
declare -a KC_GROUP_IDS=()
for G in "${KC_GROUPS[@]}"; do
  api -o /dev/null -X POST "${KC}/admin/realms/${REALM}/groups" -d "{\"name\":\"${G}\"}" >/dev/null 2>&1
  GID=$(api "${KC}/admin/realms/${REALM}/groups?search=${G}" \
    | python3 -c "import sys,json; g=[x for x in json.load(sys.stdin) if x['name']=='${G}']; print(g[0]['id'] if g else '')")
  [ -n "$GID" ] || { echo "   could not create or find group ${G}"; exit 1; }
  KC_GROUP_IDS+=("$GID")
  echo "   ${G}"
done

# --- users ------------------------------------------------------------------
# Both users join BOTH groups. An email is required, or Keycloak answers the
# direct grant with "Account is not fully set up".
echo "==> Users (both belong to both groups)"
for U in "${USERS[@]}"; do
  api -o /dev/null -X POST "${KC}/admin/realms/${REALM}/users" -d "{
    \"username\":\"${U}\",\"enabled\":true,
    \"email\":\"${U}@example.com\",\"emailVerified\":true,
    \"firstName\":\"Quota\",\"lastName\":\"Demo\",\"requiredActions\":[],
    \"credentials\":[{\"type\":\"password\",\"value\":\"${U}\",\"temporary\":false}]
  }" >/dev/null 2>&1

  UID_=$(api "${KC}/admin/realms/${REALM}/users?username=${U}&exact=true" \
    | python3 -c 'import sys,json; u=json.load(sys.stdin); print(u[0]["id"] if u else "")')
  [ -n "$UID_" ] || { echo "   could not create or find user ${U}"; exit 1; }

  # Re-assert on a re-run, in case the user already existed without these.
  api -o /dev/null -X PUT "${KC}/admin/realms/${REALM}/users/${UID_}" -d "{
    \"email\":\"${U}@example.com\",\"emailVerified\":true,\"requiredActions\":[]}" >/dev/null 2>&1
  api -o /dev/null -X PUT "${KC}/admin/realms/${REALM}/users/${UID_}/reset-password" \
    -d "{\"type\":\"password\",\"value\":\"${U}\",\"temporary\":false}" >/dev/null 2>&1
  for GID in "${KC_GROUP_IDS[@]}"; do
    api -o /dev/null -X PUT "${KC}/admin/realms/${REALM}/users/${UID_}/groups/${GID}" >/dev/null 2>&1
  done

  MEMBERSHIP=$(api "${KC}/admin/realms/${REALM}/users/${UID_}/groups" \
    | python3 -c 'import sys,json; print([g["name"] for g in json.load(sys.stdin)])')
  printf '   %-12s password %-12s groups %s\n' "$U" "$U" "$MEMBERSHIP"
done

# --- MaaS objects -----------------------------------------------------------
echo "==> Subscriptions"
oc apply -f "${DIR}/subscriptions.yaml" | sed 's/^/   /'

oc get maassubscription -n models-as-a-service \
  quota-standard-tier quota-bulk-tier quota-individual-tier \
  -o custom-columns=NAME:.metadata.name,PRIORITY:.spec.priority,LIMIT:.spec.modelRefs[0].tokenRateLimits[0].limit,WINDOW:.spec.modelRefs[0].tokenRateLimits[0].window \
  2>/dev/null | sed 's/^/   /'

# --- verify -----------------------------------------------------------------
echo "==> Verifying resolution"
MAAS=https://maas.$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
sleep 10
FAIL=0
for pair in "dual-user:quota-standard-tier" "capped-user:quota-individual-tier"; do
  U="${pair%%:*}"; WANT="${pair##*:}"
  T=$(curl -sSk -m 20 -X POST "${ISSUER}/protocol/openid-connect/token" \
    -d grant_type=password -d client_id=maas-oidc \
    -d "username=${U}" -d "password=${U}" -d scope=openid \
    | python3 -c 'import sys,json; print(json.load(sys.stdin).get("access_token",""))' 2>/dev/null)
  if [ -z "$T" ]; then echo "   ${U}: token request failed"; FAIL=1; continue; fi
  SUB=$(curl -sSk -m 30 -H "Authorization: Bearer ${T}" -H 'Content-Type: application/json' -X POST \
    -d "{\"name\":\"${U}-verify\",\"description\":\"d\",\"expiresIn\":\"10m\"}" "${MAAS}/maas-api/v1/api-keys" \
    | python3 -c 'import sys,json; print(json.load(sys.stdin).get("subscription","UNRESOLVED"))' 2>/dev/null)
  if [ "$SUB" = "$WANT" ]; then printf '   %-12s -> %s\n' "$U" "$SUB"
  else printf '   %-12s -> %s (expected %s)\n' "$U" "$SUB" "$WANT"; FAIL=1; fi
done

if [ "$FAIL" -eq 0 ]; then
  echo
  echo "Ready.  ./run-demo.sh          show which subscription each user resolves to"
  echo "        ./run-demo.sh --burn   spend real tokens and show where the limit lands"
else
  echo
  echo "Resolution did not match. Check what else these identities match:"
  echo "  oc get maassubscription -n models-as-a-service -o custom-columns=NAME:.metadata.name,PRIO:.spec.priority,GROUPS:.spec.owner.groups,USERS:.spec.owner.users"
  exit 1
fi
