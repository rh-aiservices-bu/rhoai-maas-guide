#!/usr/bin/env bash
# MaaS tiering demo: group baseline + per-user overrides.
#
#   carol -> demo-team-standard  (group tier)
#   alice -> demo-alice-gold     (per-user upgrade)
#   bob   -> demo-bob-throttled  (per-user downgrade, trips fast)
#
# Each user mints an API key WITHOUT naming a subscription - MaaS resolves the
# highest-priority subscription the user matches. That resolution is the point.
#
# Usage:
#   ./run-demo.sh [requests_per_user]           # default 12
#   DEMO_PASSWORD='...' ./run-demo.sh 20
set -uo pipefail

N=${1:-12}
USERS=(carol alice bob)
MODEL_RESOURCE=facebook-opt-125m-simulated   # KServe resource name -> URL path
MODEL_SERVED=facebook/opt-125m               # served name -> JSON body (NOT the same)

oc whoami >/dev/null 2>&1 || { echo "not logged in to a cluster"; exit 1; }
API=$(oc whoami --show-server)
CLUSTER_DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
H="https://maas.${CLUSTER_DOMAIN}"
ENDPOINT="${H}/llm/${MODEL_RESOURCE}/v1/chat/completions"

if [ -z "${DEMO_PASSWORD:-}" ]; then
  read -rsp "Password for demo users: " DEMO_PASSWORD; echo
fi

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
echo "MaaS: $H"

# Warm-up: the first request after an idle period can return 500 (stale pooled DB
# connection in maas-api). Absorb it here rather than during the demo.
curl -sk --max-time 30 -o /dev/null -H "Authorization: Bearer $(oc whoami -t)" \
  "${H}/maas-api/v1/models" 2>/dev/null || true

for U in "${USERS[@]}"; do
  printf '\n=== %s ===\n' "$U"

  KUBECONFIG="$TMP/$U.kubeconfig" oc login -u "$U" -p "$DEMO_PASSWORD" --server="$API" \
    --insecure-skip-tls-verify=true >/dev/null 2>&1 || { echo "  login FAILED"; continue; }
  TOKEN=$(KUBECONFIG="$TMP/$U.kubeconfig" oc whoami -t)

  RESP=$(curl -sk --max-time 30 -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" -X POST \
    -d "{\"name\":\"${U}-demo\",\"description\":\"demo\",\"expiresIn\":\"8h\"}" \
    "${H}/maas-api/v1/api-keys")
  echo "  resolved subscription: $(echo "$RESP" | jq -r '.subscription // "UNRESOLVED"')"
  KEY=$(echo "$RESP" | jq -r '.key // empty')
  [ -z "$KEY" ] && { echo "  no key issued: $(echo "$RESP" | head -c 140)"; continue; }

  ok=0; lim=0; other=0; tok=0
  for _ in $(seq 1 "$N"); do
    code=$(curl -sk --max-time 30 -o "$TMP/r" -w "%{http_code}" \
      -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" -X POST \
      -d "{\"model\":\"${MODEL_SERVED}\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":4}" \
      "$ENDPOINT")
    # maas-api can return 500 on the first call after an idle period (stale pooled
    # DB connection on the key-validation path). Retry once so the demo stays clean.
    if [ "$code" = "500" ]; then
      code=$(curl -sk --max-time 30 -o "$TMP/r" -w "%{http_code}" \
        -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" -X POST \
        -d "{\"model\":\"${MODEL_SERVED}\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":4}" \
        "$ENDPOINT")
    fi
    case "$code" in
      200) ok=$((ok+1)); tok=$((tok + $(jq -r '.usage.total_tokens // 0' "$TMP/r" 2>/dev/null))) ;;
      429) lim=$((lim+1)) ;;
      *)   other=$((other+1)) ;;
    esac
  done
  printf '  %s requests -> %s ok / %s rate-limited / %s other   (%s tokens consumed)\n' \
    "$N" "$ok" "$lim" "$other" "$tok"
done

printf '\nExpected: bob rate-limited at his token limit; alice and carol unaffected at this volume.\n'
