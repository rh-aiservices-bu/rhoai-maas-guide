#!/usr/bin/env bash
# Add `solo-user` - an OIDC identity whose access comes only from user-scoped
# MaaS objects, not from any group tier.
#
# The realm import (realm-import.yaml) runs once, so this adds the user through
# Keycloak's admin API instead. Idempotent: safe to re-run.
#
# What it creates:
#   Keycloak  user  solo-user / solo-user  (realm `maas`)
#   Keycloak  group no-tier               (deliberately referenced by NO subscription)
#   MaaS      MaaSAuthPolicy solo-user-access   - grants access
#   MaaS      MaaSSubscription solo-user-tier   - 30 tokens/min, priority 60
#
# Two things this script works around, both worth knowing:
#
#   1. Keycloak refuses the direct grant with "Account is not fully set up"
#      unless the user has an email - the realm's user profile requires it.
#   2. maas-api rejects a token with NO `groups` claim ("Missing group header"
#      -> HTTP 500 AUTH_FAILURE), and Keycloak omits the claim for a user in
#      zero groups. Hence the `no-tier` group: it satisfies the check while
#      granting nothing.
#
# Usage:  ./add-solo-user.sh
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REALM=maas
USERNAME=solo-user
PASSWORD=${SOLO_PASSWORD:-solo-user}
GROUP=no-tier

oc whoami >/dev/null 2>&1 || { echo "not logged in to a cluster"; exit 1; }

# --- locate Keycloak and its bootstrap admin -------------------------------
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

# --- group with no tier -----------------------------------------------------
echo "==> Group '${GROUP}' (referenced by no subscription)"
api -o /dev/null -X POST "${KC}/admin/realms/${REALM}/groups" -d "{\"name\":\"${GROUP}\"}" >/dev/null 2>&1
GROUP_ID=$(api "${KC}/admin/realms/${REALM}/groups?search=${GROUP}" \
  | python3 -c "import sys,json; g=[x for x in json.load(sys.stdin) if x['name']=='${GROUP}']; print(g[0]['id'] if g else '')")
[ -n "$GROUP_ID" ] || { echo "   could not create or find the group"; exit 1; }
echo "   id ${GROUP_ID:0:8}…"

# --- the user ---------------------------------------------------------------
# An email is required or Keycloak answers the direct grant with
# "Account is not fully set up".
echo "==> User '${USERNAME}'"
api -o /dev/null -X POST "${KC}/admin/realms/${REALM}/users" -d "{
  \"username\":\"${USERNAME}\",\"enabled\":true,
  \"email\":\"${USERNAME}@example.com\",\"emailVerified\":true,
  \"firstName\":\"Solo\",\"lastName\":\"User\",\"requiredActions\":[],
  \"credentials\":[{\"type\":\"password\",\"value\":\"${PASSWORD}\",\"temporary\":false}]
}" >/dev/null 2>&1

USER_ID=$(api "${KC}/admin/realms/${REALM}/users?username=${USERNAME}&exact=true" \
  | python3 -c 'import sys,json; u=json.load(sys.stdin); print(u[0]["id"] if u else "")')
[ -n "$USER_ID" ] || { echo "   could not create or find the user"; exit 1; }

# Re-assert on a re-run, in case the user already existed without these.
api -o /dev/null -X PUT "${KC}/admin/realms/${REALM}/users/${USER_ID}" -d "{
  \"email\":\"${USERNAME}@example.com\",\"emailVerified\":true,\"requiredActions\":[]}" >/dev/null 2>&1
api -o /dev/null -X PUT "${KC}/admin/realms/${REALM}/users/${USER_ID}/reset-password" \
  -d "{\"type\":\"password\",\"value\":\"${PASSWORD}\",\"temporary\":false}" >/dev/null 2>&1
api -o /dev/null -X PUT "${KC}/admin/realms/${REALM}/users/${USER_ID}/groups/${GROUP_ID}" >/dev/null 2>&1

MEMBERSHIP=$(api "${KC}/admin/realms/${REALM}/users/${USER_ID}/groups" \
  | python3 -c 'import sys,json; print([g["name"] for g in json.load(sys.stdin)])')
echo "   id ${USER_ID:0:8}…  groups ${MEMBERSHIP}"

# --- MaaS objects -----------------------------------------------------------
echo "==> User-scoped MaaSAuthPolicy and MaaSSubscription"
oc apply -f "${DIR}/user-scoped-access.yaml" | sed 's/^/   /'

# --- verify ------------------------------------------------------------------
echo "==> Verifying"
ISSUER=$(oc get aitenants.maas.opendatahub.io models-as-a-service -n ai-tenants -o jsonpath='{.spec.oidc.issuerUrl}' 2>/dev/null)
MAAS=https://maas.$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
sleep 10
T=$(curl -sSk -X POST "${ISSUER}/protocol/openid-connect/token" \
  -d grant_type=password -d client_id=maas-oidc \
  -d "username=${USERNAME}" -d "password=${PASSWORD}" -d scope=openid \
  | python3 -c 'import sys,json; print(json.load(sys.stdin).get("access_token",""))')
if [ -z "$T" ]; then echo "   token request failed"; exit 1; fi
echo "$T" | python3 -c 'import sys,json,base64
p=sys.stdin.read().strip().split(".")[1]; p+="="*(-len(p)%4)
c=json.loads(base64.urlsafe_b64decode(p))
print("   claims: user=%s groups=%s" % (c.get("preferred_username"), c.get("groups","(absent)")))'

SUB=$(curl -sSk -m 30 -H "Authorization: Bearer ${T}" -H 'Content-Type: application/json' -X POST \
  -d '{"name":"solo-verify","description":"d","expiresIn":"10m"}' "${MAAS}/maas-api/v1/api-keys" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin).get("subscription","UNRESOLVED"))' 2>/dev/null)
echo "   resolved subscription: ${SUB}"
[ "$SUB" = "solo-user-tier" ] \
  && echo "   OK - access and rate limit come entirely from user-scoped objects." \
  || echo "   Unexpected. If this is UNRESOLVED, check: oc logs -n redhat-ai-gateway-infra deployment/maas-api | grep -i 'group header'"
