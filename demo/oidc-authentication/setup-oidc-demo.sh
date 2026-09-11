#!/usr/bin/env bash
# Configure MaaS external OIDC authentication against an EXISTING Keycloak.
#
# MaaS needs only an OIDC issuer URL and a client ID. It does not care which
# Keycloak provides them, so if the cluster already runs one (common on RHOAI
# demo clusters, where Keycloak often backs cluster login) there is no need to
# deploy a second instance and second database.
#
# This script:
#   1. finds an existing Keycloak instance (or uses --keycloak-namespace)
#   2. imports the `maas` realm into it - a NEW realm, isolated from any existing one
#   3. derives the issuer URL from that instance's route
#   4. patches the AITenant (RHOAI 3.5+) or Tenant (3.4) with the OIDC config
#   5. applies the OIDC MaaSAuthPolicies and MaaSSubscription
#
# To deploy a standalone Keycloak instead, use the guide's own script:
#   ../../manifests/09-external-oidc/setup-keycloak.sh
#
# Usage:
#   ./setup-oidc-demo.sh
#   ./setup-oidc-demo.sh --keycloak-namespace keycloak
#   ./setup-oidc-demo.sh --keep-shipped-limits   # leave both tiers at 100000 tokens/min
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAAS_NS=models-as-a-service
OIDC_MANIFESTS="${DIR}/../../manifests/09-external-oidc/maas-oidc"
KC_NS=""
KEEP_LIMITS=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --keycloak-namespace) KC_NS="$2"; shift 2 ;;
    --keep-shipped-limits) KEEP_LIMITS=true; shift ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "unknown option: $1"; exit 1 ;;
  esac
done

oc whoami >/dev/null 2>&1 || { echo "not logged in to a cluster"; exit 1; }

# --- 1. locate an existing Keycloak -----------------------------------------
if [ -z "$KC_NS" ]; then
  # `mapfile` is bash 4+; keep this portable to the bash 3.2 on macOS.
  FOUND=$(oc get keycloak -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null | sed '/^$/d')
  COUNT=$(printf '%s\n' "$FOUND" | sed '/^$/d' | wc -l | tr -d ' ')
  [ "$COUNT" -eq 0 ] && {
    echo "No Keycloak found. Deploy one first:"
    echo "  ../../manifests/09-external-oidc/setup-keycloak.sh"
    exit 1; }
  [ "$COUNT" -gt 1 ] && {
    echo "Multiple Keycloak instances found - pick one with --keycloak-namespace:"
    printf '  %s\n' "$FOUND"; exit 1; }
  KC_NS="${FOUND%%/*}"
fi
KC_NAME=$(oc get keycloak -n "$KC_NS" -o jsonpath='{.items[0].metadata.name}')
echo "==> Using Keycloak ${KC_NS}/${KC_NAME}"

[ "$(oc get keycloak "$KC_NAME" -n "$KC_NS" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" = "True" ] \
  || { echo "Keycloak is not Ready - aborting"; exit 1; }

EXISTING=$(oc get keycloakrealmimport -n "$KC_NS" -o jsonpath='{range .items[*]}{.spec.realm.realm} {end}' 2>/dev/null)
[ -n "$EXISTING" ] && echo "    existing realms on this instance (untouched): ${EXISTING}"

# --- 2. import the maas realm -----------------------------------------------
echo "==> Importing realm 'maas' (a new realm; existing realms are not modified)"
sed "s/REALM_NAMESPACE/${KC_NS}/" "${DIR}/realm-import.yaml" | oc apply -f -

echo "==> Waiting for the realm import to complete"
for i in $(seq 1 60); do
  DONE=$(oc get keycloakrealmimport maas -n "$KC_NS" -o jsonpath='{.status.conditions[?(@.type=="Done")].status}' 2>/dev/null || true)
  [ "$DONE" = "True" ] && { echo "    realm imported"; break; }
  sleep 5
done
[ "${DONE:-}" = "True" ] || { echo "    realm import did not finish; check:"; \
  echo "      oc get keycloakrealmimport maas -n $KC_NS -o yaml"; exit 1; }

# --- 3. derive the issuer ----------------------------------------------------
KC_HOST=$(oc get keycloak "$KC_NAME" -n "$KC_NS" -o jsonpath='{.spec.hostname.hostname}' 2>/dev/null)
[ -z "$KC_HOST" ] && KC_HOST=$(oc get route -n "$KC_NS" -o jsonpath='{.items[0].spec.host}')
ISSUER="https://${KC_HOST}/realms/maas"
echo "==> Issuer: ${ISSUER}"

echo "==> Checking the discovery document is reachable"
CODE=$(curl -sSk -o /dev/null -w '%{http_code}' "${ISSUER}/.well-known/openid-configuration" || echo 000)
[ "$CODE" = "200" ] || { echo "    discovery returned HTTP ${CODE} - aborting"; exit 1; }
echo "    HTTP 200"

# --- 4. point MaaS at it -----------------------------------------------------
if oc get crd aitenants.maas.opendatahub.io >/dev/null 2>&1; then
  echo "==> RHOAI 3.5+: patching AITenant"
  oc patch aitenants.maas.opendatahub.io "$MAAS_NS" -n ai-tenants --type merge \
    -p "{\"spec\":{\"oidc\":{\"clientId\":\"maas-oidc\",\"issuerUrl\":\"${ISSUER}\",\"ttl\":300}}}"
else
  echo "==> RHOAI 3.4: patching Tenant"
  oc patch tenants.maas.opendatahub.io default-tenant -n "$MAAS_NS" --type merge \
    -p "{\"spec\":{\"externalOIDC\":{\"clientId\":\"maas-oidc\",\"issuerUrl\":\"${ISSUER}\"}}}"
fi

# --- 5. group-based access policies -----------------------------------------
echo "==> Applying OIDC auth policies and subscription"
oc apply -k "$OIDC_MANIFESTS"

# --- 6. make the tiers visibly different -------------------------------------
# Both shipped OIDC subscriptions carry the same 100000 tokens/min limit, so
# nothing throttles and the two groups look identical. Lower the data-scientists
# tier so the difference between the two demo users is actually observable.
if [ "$KEEP_LIMITS" = false ]; then
  echo "==> Lowering oidc-data-scientists to 20 tokens/min so throttling is demonstrable"
  echo "    (skip with --keep-shipped-limits)"
  oc patch maassubscription oidc-data-scientists -n "$MAAS_NS" --type=merge \
    -p '{"spec":{"modelRefs":[{"name":"facebook-opt-125m-simulated","namespace":"llm","tokenRateLimits":[{"limit":20,"window":"1m"}]}]}}' \
    >/dev/null
  echo "    oidc-data-scientists  20 tokens/min   <- restricted-user"
  echo "    oidc-ml-engineers     100000 tokens/min <- maas-user"
fi

echo
echo "Done. Issuer: ${ISSUER}"
echo "Realm users: maas-user (data-scientists + ml-engineers), restricted-user (data-scientists)"
echo "Run ./run-demo.sh to exercise it."
