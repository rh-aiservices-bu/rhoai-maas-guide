#!/usr/bin/env bash
# Prove: "Validates JWT tokens locally using cached JWKS
#         (no call to the IdP on every request)"
#
# The claim has two halves and one decisive test:
#
#   locally / cached  -> if Authorino had to ask the IdP per request, cutting
#                        Authorino off from the IdP would break validation.
#                        It does not: tokens keep validating.
#
# Method: a NetworkPolicy that blocks egress from the Authorino pod to the IdP's
# IP only. Everything else Authorino needs (the API server, maas-api, DNS, the
# rest of the cluster) is untouched, and Keycloak itself keeps running - so
# cluster login is unaffected. This is far safer than scaling the IdP down.
#
# Usage:  ./prove-cached.sh
set -uo pipefail

USER_NAME=${USER_NAME:-maas-user}
NP=deny-authorino-to-idp
NS=kuadrant-system
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

oc whoami >/dev/null 2>&1 || { echo "not logged in"; exit 1; }
ISSUER=$(oc get aitenants.maas.opendatahub.io models-as-a-service -n ai-tenants -o jsonpath='{.spec.oidc.issuerUrl}')
MAAS=https://maas.$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
IDP_HOST=$(echo "$ISSUER" | sed -E 's#https?://([^/]+)/.*#\1#')

hr(){ printf '\n\033[1m%s\033[0m\n' "$*"; }
cleanup(){ oc delete networkpolicy "$NP" -n "$NS" --ignore-not-found >/dev/null 2>&1; }
trap cleanup EXIT

# Mint an API key with the OIDC token; 201 means the JWT was validated.
validate() {
  curl -sSk -o /dev/null -m 30 -w '%{http_code}' -H "Authorization: Bearer $1" \
    -H 'Content-Type: application/json' -X POST \
    -d '{"name":"local-validation-probe","description":"d","expiresIn":"5m"}' \
    "$MAAS/maas-api/v1/api-keys"
}

hr "Setup"
echo "  issuer:   $ISSUER"

# Resolve the IdP FROM INSIDE THE CLUSTER. This matters: split-horizon DNS is
# normal here, and the address a laptop sees is not the address Authorino uses.
# Blocking the externally-resolved IP would leave Authorino's real path open and
# produce a false pass.
echo "  resolving ${IDP_HOST} from inside the cluster..."
oc delete pod dnsprobe -n "$NS" --ignore-not-found >/dev/null 2>&1
cat <<YAML | oc apply -f - >/dev/null 2>&1
apiVersion: v1
kind: Pod
metadata: {name: dnsprobe, namespace: ${NS}}
spec:
  restartPolicy: Never
  containers:
    - name: p
      image: registry.access.redhat.com/ubi9/ubi-minimal:latest
      command: ["sh","-c","getent hosts ${IDP_HOST} || true; sleep 2"]
      securityContext:
        allowPrivilegeEscalation: false
        runAsNonRoot: true
        capabilities: {drop: ["ALL"]}
        seccompProfile: {type: RuntimeDefault}
YAML
for _ in $(seq 1 20); do
  IDP_IP=$(oc logs dnsprobe -n "$NS" 2>/dev/null | awk '{print $1}' | head -1)
  [ -n "$IDP_IP" ] && break
  sleep 3
done
oc delete pod dnsprobe -n "$NS" --ignore-not-found >/dev/null 2>&1
[ -z "$IDP_IP" ] && { echo "  could not resolve ${IDP_HOST} in-cluster"; exit 1; }

# Also block whatever this machine resolves, in case egress hairpins externally.
EXT_IP=$(python3 -c "import socket; print(socket.gethostbyname('$IDP_HOST'))" 2>/dev/null)
echo "  IdP in-cluster: ${IDP_IP}   (this is the one that matters)"
[ -n "$EXT_IP" ] && [ "$EXT_IP" != "$IDP_IP" ] && echo "  IdP external:   ${EXT_IP}   (blocked too, belt and braces)"

TOKEN=$(curl -sSk -X POST "$ISSUER/protocol/openid-connect/token" \
  -d grant_type=password -d client_id=maas-oidc \
  -d "username=${USER_NAME}" -d "password=${USER_NAME}" -d scope=openid \
  | python3 -c 'import sys,json; print(json.load(sys.stdin).get("access_token",""))')
[ -n "$TOKEN" ] || { echo "  could not obtain a token"; exit 1; }
echo "  token obtained for ${USER_NAME} (issued BEFORE the IdP is cut off)"

hr "1. Baseline - IdP reachable"
B=$(validate "$TOKEN"); echo "  validate -> HTTP $B  $([ "$B" = 201 ] && echo '(ok)' || echo '(unexpected)')"
[ "$B" = "201" ] || { echo "  Baseline failed, so the later result would mean nothing. Aborting."
  echo "  If this is 503 the gateway WASM filter is failing closed; restart the gateway pods."; exit 1; }

EXCEPTS="\"${IDP_IP}/32\""
[ -n "${EXT_IP:-}" ] && [ "$EXT_IP" != "$IDP_IP" ] && EXCEPTS="${EXCEPTS}, \"${EXT_IP}/32\""

hr "2. Cut Authorino off from the IdP"
cat <<YAML | oc apply -f - | sed 's/^/  /'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: ${NP}
  namespace: ${NS}
spec:
  podSelector:
    matchLabels:
      authorino-resource: authorino
  policyTypes: [Egress]
  egress:
    # Everything is still allowed EXCEPT the IdP's address.
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
            except: [${EXCEPTS}]
YAML
echo "  waiting for the policy to take effect..."
sleep 15

echo "  proving Authorino really cannot reach the IdP now:"
oc exec -n "$NS" deployment/authorino -- \
  timeout 12 bash -c "exec 3<>/dev/tcp/${IDP_IP}/443 && echo open" 2>&1 \
  | head -2 | sed 's/^/    /' \
  || echo "    TCP to ${IDP_IP}:443 (in-cluster IdP address) FAILED - blocked, as intended"

hr "3. Validate the SAME token with the IdP unreachable"
for i in 1 2 3; do
  R=$(validate "$TOKEN")
  echo "  attempt $i -> HTTP $R"
done

echo
if [ "$R" = "201" ]; then
  cat <<'TXT'
  PASS. Authorino cannot reach the IdP, yet the token still validates.
  Therefore validation is performed locally against a cached JWKS - no
  per-request call to the IdP. If it called out per request, these would fail.
TXT
else
  cat <<TXT
  Got HTTP ${R} rather than 201.
  If the cached keys have aged past the AuthConfig ttl (300s) Authorino may
  have dropped them. Re-run soon after a successful baseline.
TXT
fi

hr "4. Restore"
cleanup
echo "  NetworkPolicy removed."
sleep 10
A=$(validate "$TOKEN"); echo "  validate with IdP reachable again -> HTTP $A"
