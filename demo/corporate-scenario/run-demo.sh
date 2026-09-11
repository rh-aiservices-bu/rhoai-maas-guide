#!/usr/bin/env bash
# Corporate scenario: demonstrate differentiated model access and rate limits.
#
# Runs one user per division (sales-1, eng-1, prod-1) through:
#   1. Model visibility - which models each division can see
#   2. Inference on allowed models - proving access + showing rate limits
#   3. Denied model access - proving 403 for unauthorized models
#
# Usage:
#   ./run-demo.sh [requests_per_model]       # default 8
#   DEMO_PASSWORD='...' ./run-demo.sh 12
set -uo pipefail

N=${1:-8}

# Models: plain variables instead of associative arrays (bash 3 compat)
GENERAL_RESOURCE="facebook-opt-125m-simulated"
GENERAL_SERVED="facebook/opt-125m"
GENERAL_NS="llm"

DEEPSEEK_RESOURCE="deepseek-r2-llmd"
DEEPSEEK_SERVED="deepseek/deepseek-r2"
DEEPSEEK_NS="llm"

GEMINI_RESOURCE="gemini-flash-cloud"
GEMINI_SERVED="google/gemini-flash"
GEMINI_NS="cloud-models"

oc whoami >/dev/null 2>&1 || { echo "not logged in to a cluster"; exit 1; }
API=$(oc whoami --show-server)
CLUSTER_DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
H="https://maas.${CLUSTER_DOMAIN}"

if [ -z "${DEMO_PASSWORD:-}" ]; then
  read -rsp "Password for demo users: " DEMO_PASSWORD; echo
fi

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
echo "MaaS endpoint: $H"
echo "Requests per model: $N"

# Warm-up: absorb stale-connection 500
curl -sk --max-time 30 -o /dev/null -H "Authorization: Bearer $(oc whoami -t)" \
  "${H}/maas-api/v1/models" 2>/dev/null || true

fire_burst() {
  local key="$1" endpoint="$2" model_served="$3" count="$4"
  local ok=0 lim=0 other=0 tok=0
  for _ in $(seq 1 "$count"); do
    code=$(curl -sk --max-time 30 -o "$TMP/r" -w "%{http_code}" \
      -H "Authorization: Bearer $key" -H "Content-Type: application/json" -X POST \
      -d "{\"model\":\"${model_served}\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":4}" \
      "$endpoint")
    if [ "$code" = "500" ]; then
      code=$(curl -sk --max-time 30 -o "$TMP/r" -w "%{http_code}" \
        -H "Authorization: Bearer $key" -H "Content-Type: application/json" -X POST \
        -d "{\"model\":\"${model_served}\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":4}" \
        "$endpoint")
    fi
    case "$code" in
      200) ok=$((ok+1)); tok=$((tok + $(jq -r '.usage.total_tokens // 0' "$TMP/r" 2>/dev/null))) ;;
      429) lim=$((lim+1)) ;;
      *)   other=$((other+1)) ;;
    esac
  done
  printf '    %s requests -> %s ok / %s rate-limited / %s other  (%s tokens)\n' \
    "$count" "$ok" "$lim" "$other" "$tok"
}

fire_denied() {
  local key="$1" endpoint="$2" model_served="$3" label="$4"
  code=$(curl -sk --max-time 30 -o "$TMP/r" -w "%{http_code}" \
    -H "Authorization: Bearer $key" -H "Content-Type: application/json" -X POST \
    -d "{\"model\":\"${model_served}\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":4}" \
    "$endpoint")
  if [ "$code" = "403" ]; then
    printf '    %s: 403 Forbidden (expected)\n' "$label"
  else
    printf '    %s: %s (expected 403!)\n' "$label" "$code"
  fi
}

login_and_key() {
  local user="$1"
  KUBECONFIG="$TMP/${user}.kubeconfig" oc login -u "$user" -p "$DEMO_PASSWORD" --server="$API" \
    --insecure-skip-tls-verify=true >/dev/null 2>&1 || { echo "  login FAILED"; return 1; }
  TOKEN=$(KUBECONFIG="$TMP/${user}.kubeconfig" oc whoami -t)

  echo "  Visible models:"
  curl -sk --max-time 30 -H "Authorization: Bearer $TOKEN" "${H}/maas-api/v1/models" \
    | jq -r '.data[]?.id // empty' 2>/dev/null | sed 's/^/    /'

  RESP=$(curl -sk --max-time 30 -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" -X POST \
    -d "{\"name\":\"${user}-demo\",\"description\":\"demo\",\"expiresIn\":\"8h\"}" \
    "${H}/maas-api/v1/api-keys")
  echo "  Resolved subscription: $(echo "$RESP" | jq -r '.subscription // "UNRESOLVED"')"
  KEY=$(echo "$RESP" | jq -r '.key // empty')
  [ -z "$KEY" ] && { echo "  no key issued: $(echo "$RESP" | head -c 140)"; return 1; }
  return 0
}

# --- sales-1 ---
printf '\n============================\n'
printf '=== sales-1 (corp-sales) ===\n'
printf '============================\n'

login_and_key "sales-1" || exit 1

echo "  General purpose (on-prem):"
fire_burst "$KEY" "${H}/${GENERAL_NS}/${GENERAL_RESOURCE}/v1/chat/completions" "${GENERAL_SERVED}" "$N"

echo "  DeepSeek R2 (on-prem):"
fire_denied "$KEY" "${H}/${DEEPSEEK_NS}/${DEEPSEEK_RESOURCE}/v1/chat/completions" "${DEEPSEEK_SERVED}" "deepseek-r2-llmd"

echo "  Gemini Flash (cloud):"
fire_denied "$KEY" "${H}/${GEMINI_NS}/${GEMINI_RESOURCE}/v1/chat/completions" "${GEMINI_SERVED}" "gemini-flash-cloud"

# --- eng-1 ---
printf '\n====================================\n'
printf '=== eng-1 (corp-engineering) ===\n'
printf '====================================\n'

login_and_key "eng-1" || exit 1

echo "  General purpose (on-prem):"
fire_burst "$KEY" "${H}/${GENERAL_NS}/${GENERAL_RESOURCE}/v1/chat/completions" "${GENERAL_SERVED}" "$N"

echo "  DeepSeek R2 (on-prem):"
fire_burst "$KEY" "${H}/${DEEPSEEK_NS}/${DEEPSEEK_RESOURCE}/v1/chat/completions" "${DEEPSEEK_SERVED}" "$N"

echo "  Gemini Flash (cloud) - expect rate limiting at ~20 tokens/min:"
fire_burst "$KEY" "${H}/${GEMINI_NS}/${GEMINI_RESOURCE}/v1/chat/completions" "${GEMINI_SERVED}" "$N"

# --- prod-1 ---
printf '\n================================\n'
printf '=== prod-1 (corp-products) ===\n'
printf '================================\n'

login_and_key "prod-1" || exit 1

echo "  General purpose (on-prem):"
fire_burst "$KEY" "${H}/${GENERAL_NS}/${GENERAL_RESOURCE}/v1/chat/completions" "${GENERAL_SERVED}" "$N"

echo "  DeepSeek R2 (on-prem):"
fire_burst "$KEY" "${H}/${DEEPSEEK_NS}/${DEEPSEEK_RESOURCE}/v1/chat/completions" "${DEEPSEEK_SERVED}" "$N"

echo "  Gemini Flash (cloud):"
fire_denied "$KEY" "${H}/${GEMINI_NS}/${GEMINI_RESOURCE}/v1/chat/completions" "${GEMINI_SERVED}" "gemini-flash-cloud"

# --- summary ---
printf '\n=== Summary ===\n'
echo "Expected behavior:"
echo "  sales-1:  sees 1 model, general OK, deepseek 403, gemini 403"
echo "  eng-1:    sees 3 models, general OK, deepseek OK, gemini rate-limited (~20 tok/min)"
echo "  prod-1:   sees 2 models, general OK, deepseek OK, gemini 403"
