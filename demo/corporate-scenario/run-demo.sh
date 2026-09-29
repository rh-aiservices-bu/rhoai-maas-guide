#!/usr/bin/env bash
# Fed Aura Capital: walk the video beats from the CLI.
#
# Scene 3 - the catalog is the policy: per-division catalog visibility
#           (one user per division; every model their division is entitled to)
# Scene 4 - the admin view: the subscription list with per-model hourly caps
# Scene 5 - the developer's day: the exact base URL + API key the IDE scene needs
#
# One inference request is fired per allowed model - enough to show access and
# the live token meter, not enough to dent the hourly caps. Rate-limit behavior
# (scene 6's real 429) is produced by ./warmup-cloud-quota.sh and verified by
# ./verify-fa-cap.sh.
#
# Usage:
#   ./run-demo.sh
#   DEMO_PASSWORD='...' ./run-demo.sh
set -uo pipefail

# Models: resource:namespace:served-name (bash 3 compat - plain vars)
MODELS="gpt-oss-120b:llm:gpt-oss/120b kimi-k3:llm:kimi/k3 nemotron-lightning:llm:nemotron/3.5-lightning claude-opus-5-1:cloud-models:claude/opus-5.1 gemini-3-pro:cloud-models:gemini/3-pro terra-large-context:cloud-models:terra/large-context"

GPT_OSS_NS=llm;          GPT_OSS_RES=gpt-oss-120b;          GPT_OSS_SERVED=gpt-oss/120b
KIMI_NS=llm;             KIMI_RES=kimi-k3;                  KIMI_SERVED=kimi/k3
NEMO_NS=llm;             NEMO_RES=nemotron-lightning;       NEMO_SERVED=nemotron/3.5-lightning
OPUS_NS=cloud-models;    OPUS_RES=claude-opus-5-1;          OPUS_SERVED=claude/opus-5.1
GEMINI_NS=cloud-models;  GEMINI_RES=gemini-3-pro;           GEMINI_SERVED=gemini/3-pro
TERRA_NS=cloud-models;   TERRA_RES=terra-large-context;     TERRA_SERVED=terra/large-context

oc whoami >/dev/null 2>&1 || { echo "not logged in to a cluster"; exit 1; }
API=$(oc whoami --show-server)
CLUSTER_DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
H="https://maas.${CLUSTER_DOMAIN}"

if [ -z "${DEMO_PASSWORD:-}" ]; then
  read -rsp "Password for demo users: " DEMO_PASSWORD; echo
fi

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
echo "MaaS endpoint: $H"
echo

# Warm-up: absorb stale-connection 500 / pod-restart transients
curl -sk --max-time 30 -o /dev/null -H "Authorization: Bearer $(oc whoami -t)" \
  "${H}/maas-api/v1/models" 2>/dev/null || true

served_for() {
  case "$1" in
    gpt-oss-120b)        echo "$GPT_OSS_SERVED" ;;
    kimi-k3)             echo "$KIMI_SERVED" ;;
    nemotron-lightning)  echo "$NEMO_SERVED" ;;
    claude-opus-5-1)     echo "$OPUS_SERVED" ;;
    gemini-3-pro)        echo "$GEMINI_SERVED" ;;
    terra-large-context) echo "$TERRA_SERVED" ;;
  esac
}

ns_for() {
  case "$1" in
    gpt-oss-120b|kimi-k3|nemotron-lightning)  echo "llm" ;;
    *)                                        echo "cloud-models" ;;
  esac
}

fire_one() {
  local key="$1" model="$2"
  local ns res served endpoint code
  ns=$(ns_for "$model"); res="$model"; served=$(served_for "$model")
  endpoint="${H}/${ns}/${res}/v1/chat/completions"
  code=$(curl -sk --max-time 30 -o "$TMP/r" -w "%{http_code}" \
    -H "Authorization: Bearer $key" -H "Content-Type: application/json" -X POST \
    -d "{\"model\":\"${served}\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":8}" \
    "$endpoint")
  if [ "$code" = "500" ]; then
    code=$(curl -sk --max-time 30 -o "$TMP/r" -w "%{http_code}" \
      -H "Authorization: Bearer $key" -H "Content-Type: application/json" -X POST \
      -d "{\"model\":\"${served}\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":8}" \
      "$endpoint")
  fi
  local toks
  toks=$(jq -r '.usage.total_tokens // 0' "$TMP/r" 2>/dev/null || echo 0)
  if [ "$code" = "200" ]; then
    printf '    %-22s 200 OK  (%s tokens)\n' "$model" "$toks"
  else
    printf '    %-22s %s (expected 200!)\n' "$model" "$code"
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

allowed_for() {
  case "$1" in
    sales-1)     echo "claude-opus-5-1 gpt-oss-120b nemotron-lightning terra-large-context" ;;
    branch-1)    echo "gpt-oss-120b nemotron-lightning" ;;
    credit-1)    echo "gpt-oss-120b nemotron-lightning" ;;
    dev-1)       echo "gpt-oss-120b kimi-k3 nemotron-lightning" ;;
    it-1)        echo "gpt-oss-120b kimi-k3 nemotron-lightning claude-opus-5-1 gemini-3-pro terra-large-context" ;;
    risk-1)      echo "gpt-oss-120b nemotron-lightning" ;;
    marketing-1) echo "claude-opus-5-1 gemini-3-pro gpt-oss-120b nemotron-lightning" ;;
  esac
}

group_for() {
  case "$1" in
    sales-1)     echo "fedaura-sales" ;;
    branch-1)    echo "fedaura-branch" ;;
    credit-1)    echo "fedaura-credit" ;;
    dev-1)       echo "fedaura-developers" ;;
    it-1)        echo "fedaura-it" ;;
    risk-1)      echo "fedaura-risk" ;;
    marketing-1) echo "fedaura-marketing" ;;
  esac
}

# ============================================================
# Scene 3 - the catalog is the policy (one user per division)
# ============================================================

DEV1_KEY=""
for user in sales-1 branch-1 credit-1 dev-1 it-1 risk-1 marketing-1; do
  grp=$(group_for "$user")
  printf '\n==============================\n'
  printf '=== %s (%s) ===\n' "$user" "$grp"
  printf '==============================\n'

  login_and_key "$user" || continue
  if [ "$user" = "dev-1" ]; then DEV1_KEY="$KEY"; fi

  echo "  One inference per allowed model:"
  for model in $(allowed_for "$user"); do
    fire_one "$KEY" "$model"
  done
done

# ============================================================
# Scene 4 - the admin view (subscription list + hourly caps)
# ============================================================

printf '\n============================================================\n'
printf '=== Scene 4 - the admin view: caps are a property of cost ===\n'
printf '============================================================\n'
echo "  One subscription per division, per-model limits (hourly + monthly):"
oc get maassubscription -n models-as-a-service -o json 2>/dev/null | jq -r '
  .items[] | select(.metadata.name | startswith("fedaura-"))
  | "  \(.metadata.name):",
    (.spec.modelRefs[] | "    \(.name) (\(.namespace)): " + ([.tokenRateLimits[] | "\(.limit) tokens / \(.window)"] | join(" + ")))' \
  || echo "  (oc query failed - run as cluster-admin)"
echo
echo "  On-prem (llm namespace) caps are generous - the GPUs are CAPEX."
echo "  Cloud (cloud-models namespace) caps are tight - rented per token."

# ============================================================
# Scene 5 - the developer's day (the IDE integration, copy-and-paste)
# ============================================================

printf '\n============================================================\n'
printf '=== Scene 5 - the developer'\''s day: copy URL + key ===\n'
printf '============================================================\n'
if [ -n "$DEV1_KEY" ]; then
  echo "  Provider name:        Red Hat AI"
  echo "  Base URL:             ${H}/v1"
  echo "  API key (dev-1):      ${DEV1_KEY}"
  echo "  Kimi K3 endpoint:     ${H}/llm/kimi-k3/v1/chat/completions"
  echo "  GPT-OSS 120B:         ${H}/llm/gpt-oss-120b/v1/chat/completions"
  echo
  echo "  Note: the dropdown lists full model IDs (publishers/<namespace>/models/<served-name>) -"
  echo "        requests to the root /v1 endpoint must use those, not the bare served name."
  echo "  Live token meter (input and output counted):"
  curl -sk --max-time 30 -H "Authorization: Bearer $DEV1_KEY" \
    -H "Content-Type: application/json" -X POST \
    -d "{\"model\":\"publishers/llm/models/kimi/k3\",\"messages\":[{\"role\":\"user\",\"content\":\"Explain rate limits in one sentence.\"}],\"max_tokens\":24}" \
    "${H}/v1/chat/completions" \
    | jq -r '"    prompt=\(.usage.prompt_tokens // 0) completion=\(.usage.completion_tokens // 0) total=\(.usage.total_tokens // 0) tokens"' 2>/dev/null
else
  echo "  dev-1 login failed - re-run to capture the scene 5 URL + key"
fi

printf '\n=== Next ===\n'
echo "  ./warmup-cloud-quota.sh   # prepare scene 6 - burn IT's Opus quota for a real 429"
echo "  ./verify-fa-cap.sh        # prove the whole 7x6 matrix holds"
echo "  ./cleanup-demo.sh         # when done"
