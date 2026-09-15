#!/usr/bin/env bash
# Set up the single-URL demo: two local models and one external model, all
# reachable through one endpoint with one API key.
#
#   facebook-opt-125m-simulated   local     (from ./scripts/setup-maas.sh)
#   gemma-4-31b-it                local     (local-model.yaml)
#   external-chat                 external  (external-provider.yaml + external-model.yaml)
#
# Access is granted to you (oc whoami) through the single-url-demo subscription.
#
# Idempotent - safe to re-run.
#
# Usage:  ./setup-demo.sh
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GW_SELECTOR=gateway.networking.k8s.io/gateway-name=maas-default-gateway

oc whoami >/dev/null 2>&1 || { echo "not logged in to a cluster"; exit 1; }
MAAS="https://maas.$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')"
PRESENTER=$(oc whoami)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# Gateway pods load their policy plugin when they start. A pod that starts while
# the Kuadrant operator is busy reconciling can come up without it; replacing
# that pod lets it load cleanly.
refresh_gateway() {
  local stale=""
  for p in $(oc get pods -n openshift-ingress -l "$GW_SELECTOR" -o name); do
    oc logs "$p" -n openshift-ingress --tail=-1 2>/dev/null | grep -q 'Retry limit exceeded' && stale="$stale $p"
  done
  if [ -n "$stale" ]; then
    echo "   refreshing gateway pods:$stale"
    oc delete -n openshift-ingress $stale --wait=false >/dev/null
  fi
}

# --- prerequisites ----------------------------------------------------------
echo "==> Prerequisites"
if [ "$(oc get maasmodelref facebook-opt-125m-simulated -n llm \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" != "True" ]; then
  echo "   the simulator model is not Ready."
  echo "   From the repository root: ./scripts/setup-maas.sh --model simulator"
  exit 1
fi
echo "   facebook-opt-125m-simulated is Ready"

# --- second local model -------------------------------------------------------
echo "==> Local model gemma-4-31b-it"
oc apply -f "${DIR}/local-model.yaml" | sed 's/^/   /'

# --- external provider ----------------------------------------------------------
echo "==> External provider (stands in for a third-party API)"
oc apply -f "${DIR}/external-provider.yaml" | sed 's/^/   /'
oc rollout status deploy/external-llm-provider -n demo-external-provider --timeout=180s | sed 's/^/   /'
HOST=$(oc get route external-llm-provider -n demo-external-provider -o jsonpath='{.spec.host}')
for i in $(seq 1 24); do
  C=$(curl -sk -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' -X POST \
      -d '{"model":"external-chat","messages":[{"role":"user","content":"ping"}],"max_tokens":4}' \
      "https://${HOST}/v1/chat/completions")
  [ "$C" = "200" ] && break
  sleep 5
done
echo "   https://${HOST}  (HTTP ${C})"

# --- external model -----------------------------------------------------------
echo "==> External model external-chat"
oc create namespace external-models --dry-run=client -o yaml | oc apply -f - >/dev/null
oc label namespace external-models maas.opendatahub.io/gateway-access=true --overwrite >/dev/null
oc create secret generic demo-provider-key --from-literal=api-key=demo-provider-api-key \
  -n external-models --dry-run=client -o yaml | oc apply -f - >/dev/null
oc label secret demo-provider-key -n external-models inference.llm-d.ai/ipp-managed=true --overwrite >/dev/null
sed "s|EXTERNAL_PROVIDER_HOST|${HOST}|" "${DIR}/external-model.yaml" > "$TMP/external-model.yaml"
oc apply -f "$TMP/external-model.yaml" | sed 's/^/   /'
for i in $(seq 1 30); do
  [ "$(oc get externalmodel.inference.opendatahub.io external-chat -n external-models -o jsonpath='{.status.phase}' 2>/dev/null)" = "Ready" ] && break
  sleep 5
done

# --- access -------------------------------------------------------------------
# A model becomes Ready once a subscription and an auth policy both cover it,
# so the readiness wait comes after this step.
echo "==> Access for ${PRESENTER}"
sed "s|PRESENTER|${PRESENTER}|" "${DIR}/access.yaml" | oc apply -f - | sed 's/^/   /'

echo "==> Waiting for the models to be Ready"
for ref in llm/gemma-4-31b-it external-models/external-chat; do
  ns="${ref%%/*}"; name="${ref##*/}"
  for i in $(seq 1 36); do
    [ "$(oc get maasmodelref "$name" -n "$ns" -o jsonpath='{.status.phase}' 2>/dev/null)" = "Ready" ] && break
    sleep 10
  done
  echo "   ${name}: $(oc get maasmodelref "$name" -n "$ns" -o jsonpath='{.status.phase}' 2>/dev/null)"
done

# --- wait until the gateway serves all three ------------------------------------
echo "==> Waiting for the gateway to serve all three models"
KEY=""
for i in $(seq 1 12); do
  KEY=$(curl -sk -m 30 -H "Authorization: Bearer $(oc whoami -t)" -H 'Content-Type: application/json' -X POST \
        -d '{"name":"single-url-setup","description":"setup check","expiresIn":"1h","subscription":"single-url-demo"}' \
        "${MAAS}/maas-api/v1/api-keys" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("key",""))' 2>/dev/null)
  [ -n "$KEY" ] && break
  sleep 10
done
[ -n "$KEY" ] || { echo "   could not create an API key for single-url-demo"; exit 1; }

READY=0
for attempt in $(seq 1 18); do
  RESULT=$(python3 - "$MAAS" "$KEY" <<'PY'
import json, ssl, sys, urllib.request, urllib.error
maas, key = sys.argv[1], sys.argv[2]
ctx = ssl.create_default_context(); ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_NONE
hdrs = {"Authorization": f"Bearer {key}", "Content-Type": "application/json"}
try:
    with urllib.request.urlopen(urllib.request.Request(f"{maas}/maas-api/v1/models", headers=hdrs), context=ctx, timeout=30) as r:
        ids = [m["id"] for m in json.loads(r.read())["data"]]
except Exception:
    print("0 models"); sys.exit()
ok = 0
for mid in ids:
    body = json.dumps({"model": mid, "messages": [{"role": "user", "content": "ping"}], "max_tokens": 4}).encode()
    try:
        with urllib.request.urlopen(urllib.request.Request(f"{maas}/v1/chat/completions", data=body, headers=hdrs, method="POST"), context=ctx, timeout=30) as r:
            ok += r.status == 200
    except urllib.error.HTTPError:
        pass
    except Exception:
        pass
print(f"{ok}/{len(ids)} models")
PY
)
  if [ "$RESULT" = "3/3 models" ]; then READY=1; break; fi
  refresh_gateway
  sleep 10
done
echo "   ${RESULT}"

if [ "$READY" -eq 1 ]; then
  echo
  echo "Ready.  ./run-demo.sh"
else
  echo
  echo "Not all three models answered yet. Re-run ./setup-demo.sh in a minute."
  exit 1
fi
