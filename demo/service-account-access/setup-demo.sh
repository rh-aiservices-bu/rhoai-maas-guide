#!/usr/bin/env bash
# Create the ServiceAccounts, the MaaS objects that grant them model access, and
# (optionally) an in-cluster app that calls the model as one of them.
#
# Idempotent - safe to re-run.
#
# Usage:
#   ./setup-demo.sh            # ServiceAccounts + MaaS objects + the app
#   ./setup-demo.sh --no-app   # skip the app
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_APP=true
[ "${1:-}" = "--no-app" ] && DEPLOY_APP=false

oc whoami >/dev/null 2>&1 || { echo "not logged in to a cluster"; exit 1; }

echo "==> ServiceAccounts"
oc apply -f "${DIR}/serviceaccounts.yaml" | sed 's/^/  /'

echo "==> MaaS auth policy and subscriptions"
oc apply -f "${DIR}/subscriptions.yaml" | sed 's/^/  /'

echo "==> Waiting for reconcile"
for _ in $(seq 1 20); do
  R=$(oc get maassubscription sa-report-writer-tier -n models-as-a-service \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
  [ "$R" = "True" ] && break
  sleep 3
done
oc get maassubscription -n models-as-a-service --no-headers 2>/dev/null \
  | grep '^sa-' | awk '{print "  "$1, $2, "priority="$3}'

if [ "$DEPLOY_APP" = true ]; then
  MAAS=https://maas.$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
  echo
  echo "==> In-cluster app (runs as the batch-scorer ServiceAccount)"
  oc create configmap model-client-code -n maas-clients \
    --from-file=app.py="${DIR}/app/app.py" --dry-run=client -o yaml \
    | oc apply -f - | sed 's/^/  /'
  sed "s|REPLACED_BY_SETUP|${MAAS}|" "${DIR}/app/deployment.yaml" \
    | oc apply -f - | sed 's/^/  /'

  # Pick up code changes on a re-run.
  oc rollout restart deployment/model-client -n maas-clients >/dev/null 2>&1
  echo "  waiting for rollout..."
  oc rollout status deployment/model-client -n maas-clients --timeout=180s 2>&1 | sed 's/^/  /'

  URL=$(oc get route model-client -n maas-clients -o jsonpath='{.spec.host}' 2>/dev/null)
  echo
  echo "  App:  https://${URL}"
  echo "  Logs: oc logs -f deployment/model-client -n maas-clients"
fi

echo
echo "Run ./run-demo.sh for the CLI walkthrough."
