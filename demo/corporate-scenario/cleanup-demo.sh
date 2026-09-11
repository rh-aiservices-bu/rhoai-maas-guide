#!/usr/bin/env bash
# Remove everything setup-demo.sh created.
#
# Deletes CRs before namespaces to avoid finalizer blocks.
# Leaves the existing general-purpose model (facebook-opt-125m-simulated) untouched.
#
# Usage:
#   ./cleanup-demo.sh
#   OAUTH_BACKUP=/path/oauth-cluster.backup.yaml ./cleanup-demo.sh
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

USERS_SALES=(sales-1 sales-2)
USERS_ENG=(eng-1 eng-2)
USERS_PROD=(prod-1 prod-2)
ALL_USERS=("${USERS_SALES[@]}" "${USERS_ENG[@]}" "${USERS_PROD[@]}")

GROUP_SALES=corp-sales
GROUP_ENG=corp-engineering
GROUP_PROD=corp-products

SECRET=corp-demo-htpasswd
IDP=corp-demo

oc whoami >/dev/null 2>&1 || { echo "not logged in to a cluster"; exit 1; }

echo "==> Removing subscriptions"
oc delete -f "${DIR}/manifests/subscriptions.yaml" --ignore-not-found 2>&1 | sed 's/^/  /'

echo "==> Removing auth policies"
oc delete -f "${DIR}/manifests/auth-policies.yaml" --ignore-not-found 2>&1 | sed 's/^/  /'

echo "==> Removing MaaSModelRef resources"
oc delete -f "${DIR}/manifests/maas-model-deepseek-r2.yaml" --ignore-not-found 2>&1 | sed 's/^/  /'
oc delete -f "${DIR}/manifests/maas-model-gemini-flash.yaml" --ignore-not-found 2>&1 | sed 's/^/  /'

echo "==> Removing LLMInferenceService resources"
oc delete -f "${DIR}/manifests/model-deepseek-r2.yaml" --ignore-not-found 2>&1 | sed 's/^/  /'
oc delete -f "${DIR}/manifests/model-gemini-flash.yaml" --ignore-not-found 2>&1 | sed 's/^/  /'

echo "==> Removing cloud-models namespace"
oc delete -f "${DIR}/manifests/namespace-cloud-models.yaml" --ignore-not-found 2>&1 | sed 's/^/  /'

echo "==> Removing groups"
for grp in $GROUP_SALES $GROUP_ENG $GROUP_PROD; do
  oc delete group "$grp" --ignore-not-found 2>&1 | sed 's/^/  /'
done

echo "==> Removing users and identities"
for u in "${ALL_USERS[@]}"; do
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
  REMAINING=$(oc get oauth cluster -o json \
    | jq -c "[.spec.identityProviders[]? | select(.name != \"${IDP}\")]")
  oc patch oauth cluster --type=merge -p "{\"spec\":{\"identityProviders\":${REMAINING}}}" 2>&1 | sed 's/^/  /'
fi

echo
echo "Identity providers now:"
oc get oauth cluster -o jsonpath='{range .spec.identityProviders[*]}  {.name} ({.type}){"\n"}{end}'
echo
echo "Cleanup complete. The existing general-purpose model was not touched."
