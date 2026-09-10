#!/usr/bin/env bash
# Remove the external OIDC demo configuration.
#
# Deletes only the `maas` realm and the MaaS OIDC config. Any other realm on the
# same Keycloak - including one backing cluster login - is left alone, and the
# Keycloak instance itself is never deleted (this demo does not create it).
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAAS_NS=models-as-a-service
OIDC_MANIFESTS="${DIR}/../../manifests/09-external-oidc/maas-oidc"
KC_NS="${1:-}"

oc whoami >/dev/null 2>&1 || { echo "not logged in to a cluster"; exit 1; }

echo "==> Removing OIDC auth policies and subscriptions"
oc delete -k "$OIDC_MANIFESTS" --ignore-not-found 2>&1 | sed 's/^/  /'
oc delete -f "${DIR}/user-scoped-access.yaml" --ignore-not-found 2>&1 | sed 's/^/  /' 

echo "==> Clearing the OIDC block from MaaS"
if oc get crd aitenants.maas.opendatahub.io >/dev/null 2>&1; then
  oc patch aitenants.maas.opendatahub.io "$MAAS_NS" -n ai-tenants --type json \
    -p '[{"op":"remove","path":"/spec/oidc"}]' 2>/dev/null | sed 's/^/  /' \
    || echo "  no oidc block present"
else
  oc patch tenants.maas.opendatahub.io default-tenant -n "$MAAS_NS" --type json \
    -p '[{"op":"remove","path":"/spec/externalOIDC"}]' 2>/dev/null | sed 's/^/  /' \
    || echo "  no externalOIDC block present"
fi

echo "==> Removing the 'maas' realm"
if [ -z "$KC_NS" ]; then
  KC_NS=$(oc get keycloakrealmimport -A -o jsonpath='{range .items[?(@.metadata.name=="maas")]}{.metadata.namespace}{end}' 2>/dev/null)
fi
if [ -n "$KC_NS" ]; then
  oc delete keycloakrealmimport maas -n "$KC_NS" --ignore-not-found 2>&1 | sed 's/^/  /'
  echo "  realms still on ${KC_NS}: $(oc get keycloakrealmimport -n "$KC_NS" -o jsonpath='{range .items[*]}{.spec.realm.realm} {end}' 2>/dev/null)"
else
  echo "  no 'maas' realm import found"
fi

echo
echo "NOTE: deleting the KeycloakRealmImport removes the CR, but the realm may"
echo "persist in the Keycloak database. To remove it fully, delete the realm in"
echo "the Keycloak admin console."
