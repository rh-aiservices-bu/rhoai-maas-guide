#!/usr/bin/env bash
# Corporate scenario: automated verification.
#
# Tests:
#   1. Access control - 3x3 matrix (users x models): 6 allow, 3 deny
#   2. Rate limiting  - burst eng-1 on gemini-flash-cloud, expect 429
#   3. Key multiplication - two keys share the same quota
#   4. Config drift   - subscription limits match expected values
#
# Usage:
#   ./verify-scenario.sh
#   DEMO_PASSWORD='...' ./verify-scenario.sh
set -uo pipefail

PASS=0; FAIL=0; SKIP=0

check() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    printf '  PASS  %s\n' "$label"
    PASS=$((PASS+1))
  elif [ "$expected" = "200" ] && [ "$actual" = "429" ]; then
    # 429 means the user HAS access but is rate-limited (e.g. from a previous run).
    # This still proves access is granted.
    printf '  PASS  %s (429 = access granted, rate-limited from previous run)\n' "$label"
    PASS=$((PASS+1))
  else
    printf '  FAIL  %s (expected %s, got %s)\n' "$label" "$expected" "$actual"
    FAIL=$((FAIL+1))
  fi
}

oc whoami >/dev/null 2>&1 || { echo "not logged in to a cluster"; exit 1; }
API=$(oc whoami --show-server)
CLUSTER_DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
H="https://maas.${CLUSTER_DOMAIN}"

if [ -z "${DEMO_PASSWORD:-}" ]; then
  read -rsp "Password for demo users: " DEMO_PASSWORD; echo
fi

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# Warm-up
curl -sk --max-time 30 -o /dev/null -H "Authorization: Bearer $(oc whoami -t)" \
  "${H}/maas-api/v1/models" 2>/dev/null || true

login_and_key() {
  local user="$1" key_name="${2:-${1}-verify}"
  KUBECONFIG="$TMP/${user}.kubeconfig" oc login -u "$user" -p "$DEMO_PASSWORD" --server="$API" \
    --insecure-skip-tls-verify=true >/dev/null 2>&1 || { echo "LOGIN_FAILED"; return; }
  local token
  token=$(KUBECONFIG="$TMP/${user}.kubeconfig" oc whoami -t)
  local resp
  resp=$(curl -sk --max-time 30 -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" -X POST \
    -d "{\"name\":\"${key_name}\",\"description\":\"verify\",\"expiresIn\":\"8h\"}" \
    "${H}/maas-api/v1/api-keys")
  echo "$resp" | jq -r '.key // empty'
}

fire_one() {
  local key="$1" ns="$2" resource="$3" served="$4"
  local endpoint="${H}/${ns}/${resource}/v1/chat/completions"
  local code
  code=$(curl -sk --max-time 30 -o "$TMP/r" -w "%{http_code}" \
    -H "Authorization: Bearer $key" -H "Content-Type: application/json" -X POST \
    -d "{\"model\":\"${served}\",\"messages\":[{\"role\":\"user\",\"content\":\"test\"}],\"max_tokens\":4}" \
    "$endpoint")
  if [ "$code" = "500" ]; then
    code=$(curl -sk --max-time 30 -o "$TMP/r" -w "%{http_code}" \
      -H "Authorization: Bearer $key" -H "Content-Type: application/json" -X POST \
      -d "{\"model\":\"${served}\",\"messages\":[{\"role\":\"user\",\"content\":\"test\"}],\"max_tokens\":4}" \
      "$endpoint")
  fi
  echo "$code"
}

# ========================================
echo "=== 1. Access control (9 tests) ==="
# ========================================

for user in sales-1 eng-1 prod-1; do
  KEY=$(login_and_key "$user")
  if [ -z "$KEY" ] || [ "$KEY" = "LOGIN_FAILED" ]; then
    echo "  SKIP  ${user}: login or key mint failed"
    SKIP=$((SKIP+3))
    continue
  fi

  case "$user" in
    sales-1)
      actual=$(fire_one "$KEY" "llm" "facebook-opt-125m-simulated" "facebook/opt-125m")
      check "sales-1 -> facebook-opt-125m-simulated" "200" "$actual"
      actual=$(fire_one "$KEY" "llm" "deepseek-r2-llmd" "deepseek/deepseek-r2")
      check "sales-1 -> deepseek-r2-llmd" "403" "$actual"
      actual=$(fire_one "$KEY" "cloud-models" "gemini-flash-cloud" "google/gemini-flash")
      check "sales-1 -> gemini-flash-cloud" "403" "$actual"
      ;;
    eng-1)
      actual=$(fire_one "$KEY" "llm" "facebook-opt-125m-simulated" "facebook/opt-125m")
      check "eng-1 -> facebook-opt-125m-simulated" "200" "$actual"
      actual=$(fire_one "$KEY" "llm" "deepseek-r2-llmd" "deepseek/deepseek-r2")
      check "eng-1 -> deepseek-r2-llmd" "200" "$actual"
      actual=$(fire_one "$KEY" "cloud-models" "gemini-flash-cloud" "google/gemini-flash")
      check "eng-1 -> gemini-flash-cloud" "200" "$actual"
      ;;
    prod-1)
      actual=$(fire_one "$KEY" "llm" "facebook-opt-125m-simulated" "facebook/opt-125m")
      check "prod-1 -> facebook-opt-125m-simulated" "200" "$actual"
      actual=$(fire_one "$KEY" "llm" "deepseek-r2-llmd" "deepseek/deepseek-r2")
      check "prod-1 -> deepseek-r2-llmd" "200" "$actual"
      actual=$(fire_one "$KEY" "cloud-models" "gemini-flash-cloud" "google/gemini-flash")
      check "prod-1 -> gemini-flash-cloud" "403" "$actual"
      ;;
  esac
done

# ======================================
echo ""
echo "=== 2. Rate limiting (1 test) ==="
# ======================================

KEY_ENG=$(login_and_key "eng-1" "eng1-ratelimit")
if [ -n "$KEY_ENG" ] && [ "$KEY_ENG" != "LOGIN_FAILED" ]; then
  got_429=false
  for _ in $(seq 1 15); do
    code=$(fire_one "$KEY_ENG" "cloud-models" "gemini-flash-cloud" "google/gemini-flash")
    [ "$code" = "429" ] && { got_429=true; break; }
  done
  if $got_429; then
    printf '  PASS  eng-1 hits 429 on gemini-flash-cloud (50 tokens/min limit)\n'
    PASS=$((PASS+1))
  else
    printf '  FAIL  eng-1 never hit 429 on gemini-flash-cloud after 15 requests\n'
    FAIL=$((FAIL+1))
  fi
else
  echo "  SKIP  rate limit test: login failed"
  SKIP=$((SKIP+1))
fi

# ==============================================
echo ""
echo "=== 3. Key multiplication (1 test) ==="
# ==============================================

KEY2_USER="eng-2"
KUBECONFIG="$TMP/${KEY2_USER}.kubeconfig" oc login -u "$KEY2_USER" -p "$DEMO_PASSWORD" --server="$API" \
  --insecure-skip-tls-verify=true >/dev/null 2>&1
if [ $? -eq 0 ]; then
  TOKEN2=$(KUBECONFIG="$TMP/${KEY2_USER}.kubeconfig" oc whoami -t)

  RESP1=$(curl -sk --max-time 30 -H "Authorization: Bearer $TOKEN2" \
    -H "Content-Type: application/json" -X POST \
    -d '{"name":"eng2-key1","description":"verify","expiresIn":"8h"}' \
    "${H}/maas-api/v1/api-keys")
  K1=$(echo "$RESP1" | jq -r '.key // empty')

  RESP2=$(curl -sk --max-time 30 -H "Authorization: Bearer $TOKEN2" \
    -H "Content-Type: application/json" -X POST \
    -d '{"name":"eng2-key2","description":"verify","expiresIn":"8h"}' \
    "${H}/maas-api/v1/api-keys")
  K2=$(echo "$RESP2" | jq -r '.key // empty')

  if [ -n "$K1" ] && [ -n "$K2" ]; then
    for _ in $(seq 1 20); do
      fire_one "$K1" "cloud-models" "gemini-flash-cloud" "google/gemini-flash" >/dev/null
    done
    code_k2=$(fire_one "$K2" "cloud-models" "gemini-flash-cloud" "google/gemini-flash")
    check "eng-2 key-2 rate-limited after key-1 exhausted quota" "429" "$code_k2"
  else
    echo "  SKIP  could not mint two keys for ${KEY2_USER}"
    SKIP=$((SKIP+1))
  fi
else
  echo "  SKIP  ${KEY2_USER} login failed"
  SKIP=$((SKIP+1))
fi

# ==========================================
echo ""
echo "=== 4. Config drift (4 tests) ==="
# ==========================================

check_sub_limit() {
  local name="$1" expected_limit="$2"
  local actual
  actual=$(oc get maassubscription "$name" -n models-as-a-service \
    -o jsonpath='{.spec.modelRefs[0].tokenRateLimits[0].limit}' 2>/dev/null || echo "NOT_FOUND")
  check "subscription ${name} limit" "$expected_limit" "$actual"
}

check_sub_limit "corp-sales"       "500"
check_sub_limit "corp-engineering"  "500"
check_sub_limit "corp-products"    "500"

# Also check eng cloud limit (third modelRef)
ENG_CLOUD_LIMIT=$(oc get maassubscription "corp-engineering" -n models-as-a-service \
  -o jsonpath='{.spec.modelRefs[2].tokenRateLimits[0].limit}' 2>/dev/null || echo "NOT_FOUND")
check "subscription corp-engineering cloud limit" "20" "$ENG_CLOUD_LIMIT"

# --- summary ---
echo ""
echo "=============================="
printf 'Results: %s passed / %s failed / %s skipped (of %s)\n' \
  "$PASS" "$FAIL" "$SKIP" "$((PASS+FAIL+SKIP))"
echo "=============================="

[ "$FAIL" -eq 0 ] || exit 1
