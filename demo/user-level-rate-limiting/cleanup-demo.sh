#!/usr/bin/env bash
# Remove everything setup-demo-users.sh and subscriptions.yaml created.
#
# Usage:
#   ./cleanup-demo.sh                                    # keeps other IdPs intact
#   OAUTH_BACKUP=/path/oauth-cluster.backup.yaml ./cleanup-demo.sh
set -uo pipefail

USERS=(alice bob carol)
GROUP=maas-demo-users
SECRET=maas-demo-htpasswd
IDP=maas-demo
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

oc whoami >/dev/null 2>&1 || { echo "not logged in to a cluster"; exit 1; }

echo "==> Removing demo subscriptions"
oc delete -f "${DIR}/subscriptions.yaml" --ignore-not-found 2>&1 | sed 's/^/  /'

echo "==> Removing group and identities"
oc delete group "$GROUP" --ignore-not-found 2>&1 | sed 's/^/  /'
for u in "${USERS[@]}"; do
  oc delete user "$u" --ignore-not-found >/dev/null 2>&1
  oc delete identity "${IDP}:${u}" --ignore-not-found >/dev/null 2>&1
done
echo "  users and identities removed"

echo "==> Removing htpasswd secret"
oc delete secret "$SECRET" -n openshift-config --ignore-not-found 2>&1 | sed 's/^/  /'

echo "==> Removing the ${IDP} identity provider"
if [ -n "${OAUTH_BACKUP:-}" ] && [ -f "$OAUTH_BACKUP" ]; then
  oc apply -f "$OAUTH_BACKUP" 2>&1 | sed 's/^/  /'
else
  # Drop just our provider by name, leaving any others in place.
  REMAINING=$(oc get oauth cluster -o json \
    | jq -c "[.spec.identityProviders[]? | select(.name != \"${IDP}\")]")
  oc patch oauth cluster --type=merge -p "{\"spec\":{\"identityProviders\":${REMAINING}}}" 2>&1 | sed 's/^/  /'
fi

echo
echo "Identity providers now:"
oc get oauth cluster -o jsonpath='{range .spec.identityProviders[*]}  {.name} ({.type}){"\n"}{end}'
echo
echo "NOTE: if you re-scoped shipped subscriptions (e.g. simulator-free/premium) to make"
echo "the demo deterministic, restore them by hand - this script does not touch them."
