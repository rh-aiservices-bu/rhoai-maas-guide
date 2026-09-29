#!/usr/bin/env bash
# Fed Aura Capital: inject synthetic consumption into the usage LokiStack.
#
# Perses has no database of its own - dashboard-5-maas-usage-logs reads the
# `usage` LokiStack (Loki in redhat-ods-monitoring, backed by MinIO), and
# consumption IS log records. This script pushes records shaped exactly like
# real gateway usage logs - same stream labels (service_name, log_name,
# log_type, model, subscription, user_id, tokens_prompt/tokens_completion/
# tokens_total, response_code, response_type) - straight through the usage
# route's Loki push API. No real quota is burned and no pod has to be warm.
#
# Every token count is a stream label, so each generated record is its own
# Loki stream; records are batched into push calls. They are backfilled over
# the last HOURS hours on an hourly grid with jitter. Loki rejects records
# older than ~7 days by default, so keep HOURS under ~160. Pushed data is
# immutable - to start over, drop the LokiStack or wait out its retention.
#
# Usage:
#   ./fake-consumption.sh
#   HOURS=12 DENSITY=4 ./fake-consumption.sh
#   USERS="dwight-from-sales andy-from-branch" ./fake-consumption.sh  # subset of users
#
# The script ends with the same sum_over_time query the scoreboard dashboard
# runs, so you can see exactly what Perses will render.
set -uo pipefail

HOURS=${HOURS:-24}
DENSITY=${DENSITY:-3}   # up to this many records per user-model-hour
USERS=${USERS:-"dwight-from-sales jim-from-sales andy-from-branch pete-from-branch lane-from-credit oscar-from-credit richard-from-developers dinesh-from-developers gilfoyle-from-it jared-from-it toby-from-risk angela-from-risk don-from-marketing peggy-from-marketing"}
BATCH_SIZE=200

oc whoami >/dev/null 2>&1 || { echo "not logged in to a cluster"; exit 1; }
CLUSTER_DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
U="https://usage-redhat-ods-monitoring.${CLUSTER_DOMAIN}"
T="Authorization: Bearer $(oc whoami -t)"

oc get lokistack usage -n redhat-ods-monitoring >/dev/null 2>&1 || {
  echo "no 'usage' LokiStack found - run: ./scripts/setup-maas.sh --from-phase 7 --with-observability"; exit 1; }

[ "$HOURS" -ge 1 ] && [ "$HOURS" -le 160 ] || {
  echo "HOURS must be 1..160 (Loki rejects records older than ~7 days)"; exit 1; }
[ "$DENSITY" -ge 1 ] && [ "$DENSITY" -le 20 ] || { echo "DENSITY must be 1..20"; exit 1; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# --- the observed stream-label template from real gateway usage logs ---

CLUSTER_LABEL="maas-default-gateway-openshift-default.openshift-ingress"
NODE_LABEL="router~10.232.0.82~maas-default-gateway-openshift-default-c7c65cf47-qwhvp.openshift-ingress~openshift-ingress.svc.cluster.local"

# user -> division (*-from-developers resolves to the developers group)
division_for() {
  case "$1" in
    *-from-sales)      echo sales ;;
    *-from-branch)     echo branch ;;
    *-from-credit)     echo credit ;;
    *-from-developers) echo developers ;;
    *-from-it)         echo it ;;
    *-from-risk)       echo risk ;;
    *-from-marketing)  echo marketing ;;
    *)           echo "" ;;
  esac
}

# division -> matrix models as "slug resp_model prompt_min prompt_max compl_min compl_max" lines
# (resp_model is what the simulator puts in the response body /model - that is
# the value the gateway logs; the ranges keep every user well under its cap)
models_for() {
  case "$1" in
    sales)      cat <<'EOF'
gpt-oss-120b gpt-oss/120b 20 300 50 1200
nemotron-lightning nemotron/3.5-lightning 10 150 20 600
claude-opus-5-1 claude/opus-5.1 50 800 100 2000
terra-large-context terra/large-context 1500 8000 100 1000
EOF
    ;;
    branch)     cat <<'EOF'
gpt-oss-120b gpt-oss/120b 10 200 20 500
nemotron-lightning nemotron/3.5-lightning 10 150 20 400
EOF
    ;;
    credit)     cat <<'EOF'
gpt-oss-120b gpt-oss/120b 30 400 40 900
nemotron-lightning nemotron/3.5-lightning 10 150 20 600
EOF
    ;;
    developers) cat <<'EOF'
gpt-oss-120b gpt-oss/120b 50 600 100 1800
kimi-k3 kimi/k3 100 1500 200 2500
nemotron-lightning nemotron/3.5-lightning 10 150 20 600
EOF
    ;;
    it)         cat <<'EOF'
gpt-oss-120b gpt-oss/120b 50 600 100 1800
kimi-k3 kimi/k3 100 1500 200 2500
nemotron-lightning nemotron/3.5-lightning 10 150 20 600
claude-opus-5-1 claude/opus-5.1 50 800 100 2000
gemini-3-pro gemini/3-pro 30 500 80 1200
terra-large-context terra/large-context 1500 8000 100 1000
EOF
    ;;
    risk)       cat <<'EOF'
gpt-oss-120b gpt-oss/120b 30 400 40 900
nemotron-lightning nemotron/3.5-lightning 10 150 20 600
EOF
    ;;
    marketing)  cat <<'EOF'
gpt-oss-120b gpt-oss/120b 20 300 50 1200
nemotron-lightning nemotron/3.5-lightning 10 150 20 600
claude-opus-5-1 claude/opus-5.1 50 800 100 2000
gemini-3-pro gemini/3-pro 30 500 80 1200
EOF
    ;;
    *)          echo "" ;;
  esac
}

rand_between() { # rand_between MIN MAX
  echo $(( $1 + RANDOM % ($2 - $1 + 1) ))
}

NOW=$(date +%s)
BATCH_N=0; RECORDS=0; PUSHES=0; FAILED=0
: > "$TMP/streams.ndjson"

push_batch() {
  [ "$BATCH_N" -eq 0 ] && return 0
  jq -sc '{streams: .}' "$TMP/streams.ndjson" > "$TMP/push.json"
  CODE=$(curl -sk --max-time 60 -o "$TMP/resp" -w '%{http_code}' -X POST \
    -H "$T" -H "Content-Type: application/json" --data @"$TMP/push.json" \
    "$U/api/logs/v1/application/loki/api/v1/push")
  if [ "$CODE" = "204" ]; then
    PUSHES=$((PUSHES+1)); RECORDS=$((RECORDS+BATCH_N))
  else
    FAILED=$((FAILED+1))
    echo "  push FAILED (HTTP ${CODE}): $(head -c 120 "$TMP/resp")"
  fi
  : > "$TMP/streams.ndjson"; BATCH_N=0
}

record() { # record USER DIV SUB RESPMODEL TS TP TC
  jq -nc \
    --arg cluster "$CLUSTER_LABEL" --arg node "$NODE_LABEL" \
    --arg sub "$3" --arg div "$2" --arg model "$4" --arg user "$1" \
    --arg tp "$5" --arg tc "$6" --arg tt "$(( $5 + $6 ))" \
    --arg ts "${7}000000000" \
    '{stream:{cluster_name:$cluster,
        groups:("[system:authenticated,fedaura-" + $div + ",system:authenticated:oauth,system:authenticated]"),
        key_id:"-", key_name:"-",
        kubernetes_namespace_name:"redhat-ods-monitoring",
        log_name:"maas-usage-log", log_type:"application",
        model:$model, node_name:$node, organization_id:"-",
        response_code:"200", response_type:"hit",
        service_name:"models-as-a-service", service_namespace:"openshift-ingress",
        subscription:$sub,
        tokens_completion:$tc, tokens_prompt:$tp, tokens_total:$tt,
        user_id:$user},
      values:[[$ts, "200 /v1/chat/completions"]]}' >> "$TMP/streams.ndjson"
  BATCH_N=$((BATCH_N+1))
  [ "$BATCH_N" -ge "$BATCH_SIZE" ] && push_batch
}

echo "Injecting synthetic consumption: ${HOURS}h backfill, up to ${DENSITY} records/user-model-hour"
echo "  route: ${U}"
echo

for user in $USERS; do
  DIV=$(division_for "$user")
  [ -n "$DIV" ] || { echo "  SKIP ${user}: not a division user"; continue; }
  SUB="fedaura-${DIV}"
  NMODELS=$(models_for "$DIV" | grep -c . || true)

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    set -- $line
    RESPMODEL=$2; PMIN=$3; PMAX=$4; CMIN=$5; CMAX=$6

    for h in $(seq 1 "$HOURS"); do
      HOUR_START=$(( NOW - h * 3600 ))
      COUNT=$(( 1 + RANDOM % DENSITY ))
      i=0
      while [ "$i" -lt "$COUNT" ]; do
        TS=$(( HOUR_START + RANDOM % 3500 ))
        TP=$(rand_between "$PMIN" "$PMAX")
        TC=$(rand_between "$CMIN" "$CMAX")
        record "$user" "$DIV" "$SUB" "$RESPMODEL" "$TP" "$TC" "$TS"
        i=$(( i + 1 ))
      done
    done
  done < <(models_for "$DIV")

  echo "  ${user} (${SUB}): ${NMODELS} models x ${HOURS}h"
done
push_batch

echo
echo "Pushed ${RECORDS} records in ${PUSHES} batch calls${FAILED:+, ${FAILED} batch calls FAILED}"
[ "$FAILED" -eq 0 ] || exit 1

# --- scoreboard: the same query dashboard-5-maas-usage-logs runs ---

sleep 8
ENC=$(jq -rn --arg q "sum by (subscription, user_id) (sum_over_time({service_name=\"models-as-a-service\", subscription=~\"fedaura-.*\", response_type=\"hit\"} | unwrap tokens_total [${HOURS}h]))" '$q|@uri')
ENC2=$(jq -rn --arg q "sum by (subscription, user_id) (count_over_time({service_name=\"models-as-a-service\", subscription=~\"fedaura-.*\", response_type=\"hit\"} [${HOURS}h]))" '$q|@uri')
TOK=$(curl -sk --max-time 30 -H "$T" "$U/api/logs/v1/application/loki/api/v1/query?query=${ENC}")
REQ=$(curl -sk --max-time 30 -H "$T" "$U/api/logs/v1/application/loki/api/v1/query?query=${ENC2}")

echo
echo "=== Scoreboard: what Perses will render (last ${HOURS}h) ==="
printf '%-20s %-14s %10s %12s\n' "subscription" "user" "requests" "tokens"
jq -rn --argjson tok "$TOK" --argjson req "$REQ" '
  [($tok.data.result // []) | .[] | {k:.metric.subscription + "/" + .metric.user_id, tokens:(.value[1] | tonumber | floor)}] as $t
  | [($req.data.result // []) | .[] | {k:.metric.subscription + "/" + .metric.user_id, req:(.value[1] | tonumber | floor)}] as $r
  | ([($t[] | .k), ($r[] | .k)] | unique | sort)[]
  | . as $key
  | [($t[] | select(.k == $key) | .tokens) // 0] as $tokens
  | [($r[] | select(.k == $key) | .req) // 0] as $n
  | ($key | split("/")) as $parts
  | [$parts[0], $parts[1], ($n | max), ($tokens | max)]
  | @tsv' | awk -F'\t' '{printf "%-20s %-14s %10d %12d\n", $1, $2, $3, $4}'
echo
echo "Open the usage-logs dashboard (Perses, usage route) with the time range set to the last ${HOURS}h."
