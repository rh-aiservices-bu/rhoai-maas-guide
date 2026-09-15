#!/usr/bin/env bash
# Remove everything the single-URL demo created.
#
# Leaves facebook-opt-125m-simulated in place - it belongs to the base MaaS
# install, not to this demo.
#
# Usage:  ./cleanup-demo.sh
set -uo pipefail

GW_SELECTOR=gateway.networking.k8s.io/gateway-name=maas-default-gateway

oc whoami >/dev/null 2>&1 || { echo "not logged in to a cluster"; exit 1; }
MAAS="https://maas.$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')"

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

echo "==> Access"
oc delete maassubscription single-url-demo -n models-as-a-service --ignore-not-found | sed 's/^/   /'
oc delete maasauthpolicy single-url-access -n models-as-a-service --ignore-not-found | sed 's/^/   /'

echo "==> External model and provider"
oc delete namespace external-models --ignore-not-found --wait=false | sed 's/^/   /'
oc delete namespace demo-external-provider --ignore-not-found --wait=false | sed 's/^/   /'

echo "==> Local model gemma-4-31b-it"
oc delete maasmodelref gemma-4-31b-it -n llm --ignore-not-found | sed 's/^/   /'
oc delete llminferenceservice gemma-4-31b-it -n llm --ignore-not-found | sed 's/^/   /'

echo "==> Checking the gateway"
sleep 30
OK=0
for i in $(seq 1 12); do
  C=$(curl -sk -m 30 -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $(oc whoami -t)" "${MAAS}/maas-api/v1/models")
  if [ "$C" = "200" ]; then OK=$((OK+1)); [ "$OK" -ge 3 ] && break; else OK=0; refresh_gateway; sleep 10; fi
done
echo "   gateway: HTTP ${C}"
echo
echo "Done."
