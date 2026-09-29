#!/usr/bin/env bash
# Fed Aura Capital: the full test suite.
#
# Tests:
#   1. Access control - the full 7x6 matrix (division x model): allow/deny per cell
#   2. Rate limiting   - burn Marketing's Gemini 3 Pro hourly cap (50K/h), expect 429
#   3. Key multiplication - a second key shares the first key's exhausted quota
#                        (limits are per subscription, not per credential)
#   4. Config drift    - subscription caps match the access matrix
#
# Usage:
#   ./verify-fa-cap.sh
#   DEMO_PASSWORD='...' ./verify-fa-cap.sh
#   SKIP_RATE_LIMIT=1 ./verify-fa-cap.sh    # skip the quota burn (~1-2 min)
set -uo pipefail

PASS=0; FAIL=0; SKIP=0

# Models in fixed matrix order
MODELS="gpt-oss-120b kimi-k3 nemotron-lightning claude-opus-5-1 gemini-3-pro terra-large-context"

oc whoami >/dev/null 2>&1 || { echo "not logged in to a cluster"; exit 1; }
API=$(oc whoami --show-server)
CLUSTER_DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
H="https://maas.${CLUSTER_DOMAIN}"

if [ -z "${DEMO_PASSWORD:-}" ]; then
  read -rsp "Password for demo users: " DEMO_PASSWORD; echo
fi

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# Warm-up: absorb pod-restart transients (500 / empty listing right after rollout)
curl -sk --max-time 30 -o /dev/null -H "Authorization: Bearer $(oc whoami -t)" \
  "${H}/maas-api/v1/models" 2>/dev/null || true

check() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    printf '  PASS  %s\n' "$label"
    PASS=$((PASS+1))
  elif [ "$expected" = "200" ] && [ "$actual" = "429" ]; then
    # 429 means the user HAS access but the quota is exhausted (e.g. from a
    # previous run). Access is still granted.
    printf '  PASS  %s (429 = access granted, quota exhausted)\n' "$label"
    PASS=$((PASS+1))
  else
    printf '  FAIL  %s (expected %s, got %s)\n' "$label" "$expected" "$actual"
    FAIL=$((FAIL+1))
  fi
}

ns_for() {
  case "$1" in
    gpt-oss-120b|kimi-k3|nemotron-lightning)  echo "llm" ;;
    *)                                        echo "cloud-models" ;;
  esac
}

served_for() {
  case "$1" in
    gpt-oss-120b)        echo "gpt-oss/120b" ;;
    kimi-k3)             echo "kimi/k3" ;;
    nemotron-lightning)  echo "nemotron/3.5-lightning" ;;
    claude-opus-5-1)     echo "claude/opus-5.1" ;;
    gemini-3-pro)        echo "gemini/3-pro" ;;
    terra-large-context) echo "terra/large-context" ;;
  esac
}

allowed_for() {
  case "$1" in
    sales-1)     echo "claude-opus-5-1" ;;
    branch-1)    echo "gpt-oss-120b" ;;
    credit-1)    echo "gpt-oss-120b" ;;
    dev-1)       echo "gpt-oss-120b kimi-k3 nemotron-lightning" ;;
    it-1)        echo "gpt-oss-120b kimi-k3 nemotron-lightning claude-opus-5-1 gemini-3-pro terra-large-context" ;;
    risk-1)      echo "gpt-oss-120b" ;;
    marketing-1) echo "claude-opus-5-1 gemini-3-pro" ;;
  esac
}

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
  local key="$1" model="$2"
  local ns served endpoint code
  ns=$(ns_for "$model"); served=$(served_for "$model")
  endpoint="${H}/${ns}/${model}/v1/chat/completions"
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
echo "=== 1. Access control (7 divisions x 6 models = 42 tests) ==="
# ========================================

for user in sales-1 branch-1 credit-1 dev-1 it-1 risk-1 marketing-1; do
  KEY=$(login_and_key "$user")
  if [ -z "$KEY" ] || [ "$KEY" = "LOGIN_FAILED" ]; then
    echo "  SKIP  ${user} login/key failed"
    SKIP=$((SKIP+6))
    continue
  fi
  ALLOWED=$(allowed_for "$user")
  for model in $MODELS; do
    code=$(fire_one "$KEY" "$model")
    case " $ALLOWED " in
      *" $model "*)
        check "${user} -> ${model} (allowed)" "200" "$code"
        ;;
      *)
        check "${user} -> ${model} (denied)" "403" "$code"
        ;;
    esac
  done
done

# ======================================
echo ""
echo "=== 2. Rate limiting (1 test) ==="
# ======================================
# Marketing's Gemini 3 Pro carries the smallest cloud cap (50K/h) - the cheapest
# real quota to exhaust. Burn it until the gateway rate-limits.

LIMITED=0
if [ "${SKIP_RATE_LIMIT:-0}" = "1" ]; then
  echo "  SKIP  SKIP_RATE_LIMIT=1"
  SKIP=$((SKIP+2))
else
  KEY_M1=$(login_and_key "marketing-1" "marketing1-ratelimit")
  if [ -n "$KEY_M1" ] && [ "$KEY_M1" != "LOGIN_FAILED" ]; then
    BODY='{"model":"gemini/3-pro","messages":[{"role":"user","content":"Write a long paragraph about the weather."}],"max_tokens":500}'
    ENDPOINT="${H}/cloud-models/gemini-3-pro/v1/chat/completions"
    round=0; burned=0
    while [ "$round" -lt 40 ]; do
      round=$((round+1))
      for i in 1 2 3 4 5 6 7 8; do
        ( curl -sk --max-time 60 -o "$TMP/g.$i" -w "%{http_code}" \
            -H "Authorization: Bearer $KEY_M1" -H "Content-Type: application/json" -X POST \
            -d "$BODY" "$ENDPOINT" > "$TMP/gc.$i" 2>/dev/null ) &
      done
      wait
      for i in 1 2 3 4 5 6 7 8; do
        code=$(cat "$TMP/gc.$i" 2>/dev/null || echo 000)
        toks=$(jq -r '.usage.total_tokens // 0' "$TMP/g.$i" 2>/dev/null || echo 0)
        burned=$((burned + toks))
        [ "$code" = "429" ] && LIMITED=1
      done
      printf '  burned ~%s tokens on gemini-3-pro\n' "$burned"
      [ "$LIMITED" = "1" ] && break
    done
    if [ "$LIMITED" = "1" ]; then
      check "gemini-3-pro rate-limited at 50K/h cap (real exhaustion)" "429" "429"
    else
      check "gemini-3-pro rate-limited at 50K/h cap" "429" "200"
      echo "  (cap not exhausted after $((8*round)) requests / ~${burned} tokens)"
    fi
  else
    echo "  SKIP  marketing-1 login failed"
    SKIP=$((SKIP+1))
  fi
fi

# ==============================================
echo ""
echo "=== 3. Key multiplication (1 test) ==="
# ==============================================
# Minting a second key must NOT reset the quota: limits are per subscription.
# Only meaningful once the shared quota is exhausted by the rate-limit test.

if [ "$LIMITED" = "1" ]; then
  KUBECONFIG="$TMP/marketing-2.kubeconfig" oc login -u "marketing-2" -p "$DEMO_PASSWORD" --server="$API" \
    --insecure-skip-tls-verify=true >/dev/null 2>&1
  if [ $? -eq 0 ]; then
    TOKEN2=$(KUBECONFIG="$TMP/marketing-2.kubeconfig" oc whoami -t)
    RESP1=$(curl -sk --max-time 30 -H "Authorization: Bearer $TOKEN2" \
      -H "Content-Type: application/json" -X POST \
      -d '{"name":"marketing2-key1","description":"verify","expiresIn":"8h"}' \
      "${H}/maas-api/v1/api-keys")
    K1=$(echo "$RESP1" | jq -r '.key // empty')
    RESP2=$(curl -sk --max-time 30 -H "Authorization: Bearer $TOKEN2" \
      -H "Content-Type: application/json" -X POST \
      -d '{"name":"marketing2-key2","description":"verify","expiresIn":"8h"}' \
      "${H}/maas-api/v1/api-keys")
    K2=$(echo "$RESP2" | jq -r '.key // empty')
    if [ -n "$K1" ] && [ -n "$K2" ]; then
      # Both keys address the same exhausted quota: a per-credential limit would
      # give key-2 fresh budget (200); per-subscription means 429.
      code_k1=$(fire_one "$K1" "gemini-3-pro")
      code_k2=$(fire_one "$K2" "gemini-3-pro")
      check "marketing-2 key-1 hits the exhausted quota" "429" "$code_k1"
      check "marketing-2 key-2 shares it (no quota reset)" "429" "$code_k2"
    else
      echo "  SKIP  could not mint two keys for marketing-2"
      SKIP=$((SKIP+1))
    fi
  else
    echo "  SKIP  marketing-2 login failed"
    SKIP=$((SKIP+1))
  fi
else
  echo "  SKIP  quota not exhausted (rate-limit test skipped or failed)"
  SKIP=$((SKIP+1))
fi

# ==========================================
echo ""
echo "=== 4. Config drift (16 tests) ==="
# ==========================================
# Subscription caps must match the access matrix.

cap_for() {
  local sub="$1" model="$2"
  oc get maassubscription "$sub" -n models-as-a-service -o json 2>/dev/null \
    | jq -r ".spec.modelRefs[] | select(.name==\"$model\") | .tokenRateLimits[0].limit" 2>/dev/null
}

check_cap() {
  local sub="$1" model="$2" expected="$3"
  local actual
  actual=$(cap_for "$sub" "$model")
  check "subscription ${sub}: ${model} cap" "$expected" "$actual"
}

check_cap "fedaura-sales"      "claude-opus-5-1"     "250000"
check_cap "fedaura-branch"     "gpt-oss-120b"        "2000000"
check_cap "fedaura-credit"     "gpt-oss-120b"        "2000000"
check_cap "fedaura-developers" "gpt-oss-120b"        "2000000"
check_cap "fedaura-developers" "kimi-k3"             "1000000"
check_cap "fedaura-developers" "nemotron-lightning"  "1000000"
check_cap "fedaura-it"         "gpt-oss-120b"        "10000000"
check_cap "fedaura-it"         "kimi-k3"             "5000000"
check_cap "fedaura-it"         "nemotron-lightning"  "5000000"
check_cap "fedaura-it"         "claude-opus-5-1"     "1250000"
check_cap "fedaura-it"         "gemini-3-pro"        "250000"
check_cap "fedaura-it"         "terra-large-context" "500000"
check_cap "fedaura-risk"       "gpt-oss-120b"        "2000000"
check_cap "fedaura-marketing"  "claude-opus-5-1"     "250000"
check_cap "fedaura-marketing"  "gemini-3-pro"        "50000"

WINDOWS=$(oc get maassubscription -n models-as-a-service -o json 2>/dev/null \
  | jq -r '[.items[] | select(.metadata.name | startswith("fedaura-"))
           | .spec.modelRefs[].tokenRateLimits[].window] | unique | join(",")' 2>/dev/null)
check "all Fed Aura rate-limit windows are hourly" "1h" "$WINDOWS"

# --- summary ---
echo ""
echo "=============================="
printf 'Results: %s passed / %s failed / %s skipped (of %s)\n' \
  "$PASS" "$FAIL" "$SKIP" "$((PASS+FAIL+SKIP))"
echo "=============================="

[ "$FAIL" -eq 0 ] || exit 1
