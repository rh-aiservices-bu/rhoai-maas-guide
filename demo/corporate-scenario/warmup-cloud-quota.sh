#!/usr/bin/env bash
# Fed Aura Capital: burn down a cloud model's hourly quota for a real 429.
#
# Scene 6 shows the IT admin rate-limited on Claude Opus 5.1 ("55 minutes
# later..."). This script makes that true: it burns the model's hourly token cap
# until the gateway rate-limits - so the 429 on camera is real, earned
# exhaustion of a real cap, not a mock.
#
# After the 429 it proves the guardrail the story claims: the on-prem GPT-OSS
# 120B is untouched by the cloud cap and still generates.
#
# Usage:
#   DEMO_PASSWORD='...' ./warmup-cloud-quota.sh
#   USER_NAME=it-1 MODEL=claude-opus-5-1 MAX_TOKENS=1000 PARALLEL=16 ./warmup-cloud-quota.sh
#
# USER_NAME/MODEL must be a division/model pair from the access matrix.
set -uo pipefail

USER_NAME=${USER_NAME:-it-1}
MODEL=${MODEL:-claude-opus-5-1}
MAX_TOKENS=${MAX_TOKENS:-1000}
PARALLEL=${PARALLEL:-16}
MAX_ROUNDS=${MAX_ROUNDS:-80}

oc whoami >/dev/null 2>&1 || { echo "not logged in to a cluster"; exit 1; }
API=$(oc whoami --show-server)
CLUSTER_DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
H="https://maas.${CLUSTER_DOMAIN}"

if [ -z "${DEMO_PASSWORD:-}" ]; then
  read -rsp "Password for demo users: " DEMO_PASSWORD; echo
fi

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

group_for() {
  case "$USER_NAME" in
    sales-1)     echo "fedaura-sales" ;;
    branch-1)    echo "fedaura-branch" ;;
    credit-1)    echo "fedaura-credit" ;;
    dev-1)       echo "fedaura-developers" ;;
    it-1)        echo "fedaura-it" ;;
    risk-1)      echo "fedaura-risk" ;;
    marketing-1) echo "fedaura-marketing" ;;
    *)           echo "" ;;
  esac
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

GROUP=$(group_for)
[ -n "$GROUP" ] || { echo "USER_NAME '$USER_NAME' is not a division user (sales-1, branch-1, credit-1, dev-1, it-1, risk-1, marketing-1)"; exit 1; }
NS=$(ns_for "$MODEL"); SERVED=$(served_for "$MODEL")
ENDPOINT="${H}/${NS}/${MODEL}/v1/chat/completions"

# Read the model's hourly cap straight from the live subscription
SUB=fedaura-$(echo "$GROUP" | sed 's/^fedaura-//')
CAP=$(oc get maassubscription "$SUB" -n models-as-a-service -o json 2>/dev/null \
  | jq -r ".spec.modelRefs[] | select(.name==\"$MODEL\") | .tokenRateLimits[0].limit" 2>/dev/null)
[ -n "$CAP" ] && [ "$CAP" != "null" ] || { echo "no cap found for ${MODEL} in subscription ${SUB}"; exit 1; }

echo "Burning the hourly quota of ${MODEL} (${NS} namespace) for ${USER_NAME}"
echo "  subscription: ${SUB}   cap: ${CAP} tokens / 1h"
echo "  request size: ${MAX_TOKENS} max_tokens x ${PARALLEL} parallel"
echo

# --- login and mint a key ---

KUBECONFIG="$TMP/${USER_NAME}.kubeconfig" oc login -u "$USER_NAME" -p "$DEMO_PASSWORD" --server="$API" \
  --insecure-skip-tls-verify=true >/dev/null 2>&1 || { echo "login FAILED for ${USER_NAME}"; exit 1; }
TOKEN=$(KUBECONFIG="$TMP/${USER_NAME}.kubeconfig" oc whoami -t)

RESP=$(curl -sk --max-time 30 -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" -X POST \
  -d "{\"name\":\"${USER_NAME}-warmup\",\"description\":\"quota warmup\",\"expiresIn\":\"8h\"}" \
  "${H}/maas-api/v1/api-keys")
KEY=$(echo "$RESP" | jq -r '.key // empty')
[ -n "$KEY" ] || { echo "no key issued: $(echo "$RESP" | head -c 140)"; exit 1; }

BODY="{\"model\":\"${SERVED}\",\"messages\":[{\"role\":\"user\",\"content\":\"Write a long paragraph about the weather.\"}],\"max_tokens\":${MAX_TOKENS}}"

# --- burn ---

burned=0; round=0; limited=0
while [ "$burned" -lt "$CAP" ] && [ "$round" -lt "$MAX_ROUNDS" ]; do
  round=$((round+1))
  for i in $(seq 1 "$PARALLEL"); do
    ( curl -sk --max-time 60 -o "$TMP/b.$i" -w "%{http_code}" \
        -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" -X POST \
        -d "$BODY" "$ENDPOINT" > "$TMP/c.$i" 2>/dev/null ) &
  done
  wait
  for i in $(seq 1 "$PARALLEL"); do
    code=$(cat "$TMP/c.$i" 2>/dev/null || echo 000)
    toks=$(jq -r '.usage.total_tokens // 0' "$TMP/b.$i" 2>/dev/null || echo 0)
    burned=$((burned + toks))
    if [ "$code" = "429" ]; then limited=1; fi
  done
  if [ $((round % 5)) -eq 0 ] || [ "$limited" = "1" ]; then
    printf '  round %3d: %7d / %s tokens burned\n' "$round" "$burned" "$CAP"
  fi
  [ "$limited" = "1" ] && break
done

if [ "$limited" != "1" ]; then
  echo
  echo "Cap NOT exhausted after ${MAX_ROUNDS} rounds (${burned} tokens)."
  echo "Check: subscription ${SUB}, model ${MODEL} cap, and PARALLEL/MAX_TOKENS."
  exit 1
fi

echo
echo "=== 429 on ${MODEL} - quota genuinely exhausted (${burned} tokens burned) ==="

# --- the guardrail: another model from the same division still generates ---
# For IT this is the on-prem GPT-OSS 120B (scene 6: switch the dropdown and
# continue). Divisions with a single model have no fallback to prove.

fallback_for() {
  local allowed
  case "$USER_NAME" in
    it-1)        allowed="gpt-oss-120b kimi-k3 nemotron-lightning claude-opus-5-1 gemini-3-pro terra-large-context" ;;
    dev-1)       allowed="gpt-oss-120b kimi-k3 nemotron-lightning" ;;
    sales-1)     allowed="claude-opus-5-1" ;;
    branch-1|credit-1|risk-1) allowed="gpt-oss-120b" ;;
    marketing-1) allowed="claude-opus-5-1 gemini-3-pro" ;;
    *)           allowed="" ;;
  esac
  for m in $allowed; do [ "$m" != "$MODEL" ] && { echo "$m"; return; }; done
  echo ""
}

FB=$(fallback_for)
if [ -n "$FB" ]; then
  FB_NS=$(ns_for "$FB"); FB_SERVED=$(served_for "$FB")
  FALLBACK_CODE=$(curl -sk --max-time 30 -o "$TMP/fb" -w "%{http_code}" \
    -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" -X POST \
    -d "{\"model\":\"${FB_SERVED}\",\"messages\":[{\"role\":\"user\",\"content\":\"Keep going.\"}],\"max_tokens\":8}" \
    "${H}/${FB_NS}/${FB}/v1/chat/completions")
  if [ "$FALLBACK_CODE" = "200" ]; then
    echo "=== ${FB} still generates (200) - switch the dropdown and continue ==="
  else
    echo "WARNING: fallback ${FB} returned ${FALLBACK_CODE} (expected 200)"
  fi
else
  echo "No alternate model for this division - fallback proof skipped."
fi

# --- next hourly boundary (estimate; window alignment is platform-internal) ---

echo
if date -v+1H >/dev/null 2>&1; then
  echo "Next hourly boundary (estimate): $(date -v+1H '+%Y-%m-%d %H:00') - until then ${MODEL} stays rate-limited for ${USER_NAME}."
else
  echo "Next hourly boundary (estimate): $(date -d '+1 hour' '+%Y-%m-%d %H:00') - until then ${MODEL} stays rate-limited for ${USER_NAME}."
fi
