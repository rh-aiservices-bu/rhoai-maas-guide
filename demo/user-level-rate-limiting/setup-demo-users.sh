#!/usr/bin/env bash
# Create demo users for the MaaS tiering demo.
#
# Adds an htpasswd identity provider ALONGSIDE whatever the cluster already uses,
# creates three users, and puts them in an OpenShift group. Existing identity
# providers are left untouched.
#
# Usage:
#   ./setup-demo-users.sh                 # password prompted, or set DEMO_PASSWORD
#   DEMO_PASSWORD='...' ./setup-demo-users.sh
#
# Reverse with ./cleanup-demo.sh
set -euo pipefail

USERS=(alice bob carol)
GROUP=maas-demo-users
SECRET=maas-demo-htpasswd
IDP=maas-demo
WORKDIR=${WORKDIR:-$(mktemp -d)}

command -v htpasswd >/dev/null || { echo "htpasswd not found (install httpd-tools / apache2-utils)"; exit 1; }
oc whoami >/dev/null 2>&1 || { echo "not logged in to a cluster"; exit 1; }

if [ -z "${DEMO_PASSWORD:-}" ]; then
  read -rsp "Password for demo users: " DEMO_PASSWORD; echo
fi
[ -n "$DEMO_PASSWORD" ] || { echo "empty password"; exit 1; }

echo "==> Backing up oauth/cluster to ${WORKDIR}/oauth-cluster.backup.yaml"
oc get oauth cluster -o yaml > "${WORKDIR}/oauth-cluster.backup.yaml"

echo "==> Generating htpasswd for: ${USERS[*]}"
HT="${WORKDIR}/demo.htpasswd"
htpasswd -c -B -b "$HT" "${USERS[0]}" "$DEMO_PASSWORD" >/dev/null 2>&1
for u in "${USERS[@]:1}"; do htpasswd -B -b "$HT" "$u" "$DEMO_PASSWORD" >/dev/null 2>&1; done

echo "==> Creating secret ${SECRET} in openshift-config"
oc create secret generic "$SECRET" --from-file=htpasswd="$HT" -n openshift-config \
  --dry-run=client -o yaml | oc apply -f -

if oc get oauth cluster -o jsonpath='{.spec.identityProviders[*].name}' | tr ' ' '\n' | grep -qx "$IDP"; then
  echo "==> Identity provider ${IDP} already present, skipping"
else
  echo "==> Adding identity provider ${IDP} (additive - existing providers untouched)"
  oc patch oauth cluster --type=json -p "[{\"op\":\"add\",\"path\":\"/spec/identityProviders/-\",\"value\":{\"name\":\"${IDP}\",\"mappingMethod\":\"claim\",\"type\":\"HTPasswd\",\"htpasswd\":{\"fileData\":{\"name\":\"${SECRET}\"}}}}]"
fi

echo "==> Creating group ${GROUP}"
oc adm groups new "$GROUP" "${USERS[@]}" 2>/dev/null || \
  { for u in "${USERS[@]}"; do oc adm groups add-users "$GROUP" "$u" >/dev/null 2>&1 || true; done; }

echo
echo "Identity providers now:"
oc get oauth cluster -o jsonpath='{range .spec.identityProviders[*]}  {.name} ({.type}){"\n"}{end}'
echo
echo "The oauth pods restart before the new users can log in (usually under a minute)."
echo "Backup and htpasswd kept in: ${WORKDIR}"
echo
echo "IMPORTANT: any subscription granting system:authenticated will also match these"
echo "users and may outrank the demo tiers. Check with:"
echo "  oc get maassubscription -A -o custom-columns=NAME:.metadata.name,GROUPS:.spec.owner.groups,USERS:.spec.owner.users,PRIO:.spec.priority"
