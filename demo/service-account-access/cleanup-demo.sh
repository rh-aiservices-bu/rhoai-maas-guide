#!/usr/bin/env bash
# Remove everything this demo created.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
oc whoami >/dev/null 2>&1 || { echo "not logged in to a cluster"; exit 1; }

echo "==> Removing the in-cluster app"
oc delete -f "${DIR}/app/deployment.yaml" --ignore-not-found 2>&1 | sed 's/^/  /'
oc delete configmap model-client-code -n maas-clients --ignore-not-found 2>&1 | sed 's/^/  /'

echo "==> Removing MaaS objects"
oc delete -f "${DIR}/subscriptions.yaml" --ignore-not-found 2>&1 | sed 's/^/  /'

echo "==> Removing ServiceAccounts and namespace"
oc delete -f "${DIR}/serviceaccounts.yaml" --ignore-not-found 2>&1 | sed 's/^/  /'

echo
echo "Done. Any API keys already issued to these ServiceAccounts remain valid"
echo "until they expire - deleting the ServiceAccount does not revoke them."
