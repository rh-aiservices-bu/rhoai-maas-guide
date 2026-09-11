#!/usr/bin/env bash
# Remove everything the subscription priority demo created.
#
# Leaves the `maas` realm, its client and the OIDC demo's own users in place -
# this demo adds to that realm rather than owning it.
#
# Usage:  ./cleanup-demo.sh
set -uo pipefail

REALM=maas
declare -a KC_GROUPS=("quota-standard" "quota-bulk")
declare -a USERS=("dual-user" "capped-user")

oc whoami >/dev/null 2>&1 || { echo "not logged in to a cluster"; exit 1; }

echo "==> MaaS objects"
oc delete maassubscription -n models-as-a-service \
  quota-standard-tier quota-bulk-tier quota-individual-tier \
  --ignore-not-found 2>/dev/null | sed 's/^/   /'
oc delete maasauthpolicy -n models-as-a-service quota-groups-access \
  --ignore-not-found 2>/dev/null | sed 's/^/   /'

# --- Keycloak ---------------------------------------------------------------
KC_NS=$(oc get keycloakrealmimport -A -o jsonpath="{range .items[?(@.spec.realm.realm=='${REALM}')]}{.metadata.namespace}{end}" 2>/dev/null)
[ -z "$KC_NS" ] && KC_NS=$(oc get keycloak -A -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null)
if [ -z "$KC_NS" ]; then
  echo "==> No Keycloak found - nothing else to remove"
  exit 0
fi
KC_HOST=$(oc get keycloak -n "$KC_NS" -o jsonpath='{.items[0].spec.hostname.hostname}' 2>/dev/null)
[ -z "$KC_HOST" ] && KC_HOST=$(oc get route -n "$KC_NS" -o jsonpath='{.items[0].spec.host}')
KC="https://${KC_HOST}"

ADMIN_USER=$(oc get secret keycloak-initial-admin -n "$KC_NS" -o jsonpath='{.data.username}' 2>/dev/null | base64 -d)
ADMIN_PASS=$(oc get secret keycloak-initial-admin -n "$KC_NS" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)
AT=$(curl -sSk -X POST "${KC}/realms/master/protocol/openid-connect/token" \
  -d grant_type=password -d client_id=admin-cli \
  -d "username=${ADMIN_USER}" -d "password=${ADMIN_PASS}" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin).get("access_token",""))' 2>/dev/null)
[ -n "$AT" ] || { echo "==> Could not authenticate to Keycloak - remove the users and groups by hand"; exit 0; }

api() { curl -sSk -H "Authorization: Bearer ${AT}" -H 'Content-Type: application/json' "$@"; }

echo "==> Keycloak users"
for U in "${USERS[@]}"; do
  UID_=$(api "${KC}/admin/realms/${REALM}/users?username=${U}&exact=true" \
    | python3 -c 'import sys,json; u=json.load(sys.stdin); print(u[0]["id"] if u else "")' 2>/dev/null)
  if [ -n "$UID_" ]; then
    api -o /dev/null -X DELETE "${KC}/admin/realms/${REALM}/users/${UID_}" >/dev/null 2>&1
    echo "   removed ${U}"
  else
    echo "   ${U} not present"
  fi
done

echo "==> Keycloak groups"
for G in "${KC_GROUPS[@]}"; do
  GID=$(api "${KC}/admin/realms/${REALM}/groups?search=${G}" \
    | python3 -c "import sys,json; g=[x for x in json.load(sys.stdin) if x['name']=='${G}']; print(g[0]['id'] if g else '')" 2>/dev/null)
  if [ -n "$GID" ]; then
    api -o /dev/null -X DELETE "${KC}/admin/realms/${REALM}/groups/${GID}" >/dev/null 2>&1
    echo "   removed ${G}"
  else
    echo "   ${G} not present"
  fi
done

echo
echo "Done. API keys already issued to these users expire on their own."
