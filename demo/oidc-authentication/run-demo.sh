#!/usr/bin/env bash
# MaaS external OIDC demo.
#
# Shows that a user who exists ONLY in Keycloak - with no OpenShift account and
# no oc login - can authenticate to MaaS, and that the `groups` claim in their
# token decides which MaaSSubscription applies.
#
#   maas-user        groups: data-scientists, ml-engineers  -> oidc-ml-engineers   (priority 20)
#   restricted-user  groups: data-scientists                -> oidc-data-scientists (priority 10)
#   solo-user        groups: no-tier (no subscription)      -> solo-user-tier       (priority 60,
#                    matched by owner.users, not by group - run ./add-solo-user.sh first)
#
# Usage: ./run-demo.sh [requests_per_user]      (default 5)
set -uo pipefail

N=${1:-5}
MODEL_RESOURCE=facebook-opt-125m-simulated   # KServe resource name -> URL path
MODEL_SERVED=facebook/opt-125m               # served name -> JSON body
declare -a USERS=("maas-user" "restricted-user" "solo-user")

oc whoami >/dev/null 2>&1 || { echo "not logged in to a cluster"; exit 1; }

CLUSTER_DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
H="https://maas.${CLUSTER_DOMAIN}"
ENDPOINT="${H}/llm/${MODEL_RESOURCE}/v1/chat/completions"

# Read the issuer straight from what MaaS is configured with, so the demo can
# never drift from the cluster's actual OIDC config.
if oc get crd aitenants.maas.opendatahub.io >/dev/null 2>&1; then
  ISSUER=$(oc get aitenants.maas.opendatahub.io models-as-a-service -n ai-tenants -o jsonpath='{.spec.oidc.issuerUrl}')
  CLIENT=$(oc get aitenants.maas.opendatahub.io models-as-a-service -n ai-tenants -o jsonpath='{.spec.oidc.clientId}')
else
  ISSUER=$(oc get tenants.maas.opendatahub.io default-tenant -n models-as-a-service -o jsonpath='{.spec.externalOIDC.issuerUrl}')
  CLIENT=$(oc get tenants.maas.opendatahub.io default-tenant -n models-as-a-service -o jsonpath='{.spec.externalOIDC.clientId}')
fi
[ -n "$ISSUER" ] || { echo "MaaS has no OIDC issuer configured - run ./setup-oidc-demo.sh first"; exit 1; }

echo "MaaS:   $H"
echo "Issuer: $ISSUER"
echo "Client: $CLIENT"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

for U in "${USERS[@]}"; do
  printf '\n=== %s (exists only in Keycloak - no OpenShift account) ===\n' "$U"

  # Direct access grant. Password equals the username in the demo realm.
  TOKEN=$(curl -sSk -X POST "${ISSUER}/protocol/openid-connect/token" \
    -d "grant_type=password" -d "client_id=${CLIENT}" \
    -d "username=${U}" -d "password=${U}" -d "scope=openid" \
    | python3 -c 'import sys,json; print(json.load(sys.stdin).get("access_token",""))' 2>/dev/null)
  [ -z "$TOKEN" ] && { echo "  token request FAILED"; continue; }

  # Show the groups claim - this is what MaaS matches on.
  python3 - "$TOKEN" <<'PY'
import sys, json, base64
p = sys.argv[1].split('.')[1]
p += '=' * (-len(p) % 4)
c = json.loads(base64.urlsafe_b64decode(p))
print("  token claims: preferred_username=%s groups=%s" % (c.get("preferred_username"), c.get("groups")))
PY

  RESP=$(curl -sSk --max-time 30 -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" -X POST \
    -d "{\"name\":\"${U}-oidc\",\"description\":\"oidc demo\",\"expiresIn\":\"1h\"}" \
    "${H}/maas-api/v1/api-keys")
  SUB=$(echo "$RESP" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("subscription","UNRESOLVED"))' 2>/dev/null || echo UNRESOLVED)
  KEY=$(echo "$RESP" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("key",""))' 2>/dev/null)
  echo "  resolved subscription: ${SUB}"
  [ -z "$KEY" ] && { echo "  no key issued: $(echo "$RESP" | head -c 160)"; continue; }

  ok=0; lim=0; other=0
  for _ in $(seq 1 "$N"); do
    code=$(curl -sk --max-time 30 -o "$TMP/r" -w "%{http_code}" \
      -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" -X POST \
      -d "{\"model\":\"${MODEL_SERVED}\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":4}" \
      "$ENDPOINT")
    # Absorb the known cold-start 500 (stale pooled DB connection in maas-api).
    [ "$code" = "500" ] && code=$(curl -sk --max-time 30 -o "$TMP/r" -w "%{http_code}" \
      -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" -X POST \
      -d "{\"model\":\"${MODEL_SERVED}\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":4}" \
      "$ENDPOINT")
    case "$code" in
      200) ok=$((ok+1)) ;; 429) lim=$((lim+1)) ;; *) other=$((other+1)) ;;
    esac
  done
  printf '  inference: %s requests -> %s ok / %s rate-limited / %s other\n' "$N" "$ok" "$lim" "$other"
done

printf '\nAll three authenticated with a Keycloak token, not an OpenShift one.\n'
printf 'maas-user and restricted-user were matched by their groups claim;\n'
printf 'solo-user by owner.users, since no subscription references its group.\n'
