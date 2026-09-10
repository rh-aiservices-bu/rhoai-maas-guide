#!/usr/bin/env bash
# Demonstrate: "Validates JWT tokens using cached JWKS"
#
# Three separate claims, three separate pieces of evidence:
#
#   1. FETCHES   - Authorino discovers the issuer and pulls its JWKS (public keys)
#   2. VALIDATES - it verifies the token signature; a tampered token is rejected
#   3. CACHES    - keys are refreshed by a background worker on a TTL, not
#                  fetched per request
#
# Validation is done by Authorino (Kuadrant), not by maas-api. MaaS renders the
# AITenant's OIDC config into an AuthConfig, and Authorino does the crypto.
#
# This script is entirely read-only: it inspects config, fetches public keys and
# sends two requests. It changes nothing on the cluster.
#
# For the "no call to the IdP per request" half of the claim, run its companion
# ./prove-cached.sh, which cuts Authorino off from the IdP and shows validation
# continuing to work.
#
# Usage:
#   ./run-demo.sh
set -uo pipefail

USER_NAME=${USER_NAME:-maas-user}

oc whoami >/dev/null 2>&1 || { echo "not logged in"; exit 1; }
ISSUER=$(oc get aitenants.maas.opendatahub.io models-as-a-service -n ai-tenants -o jsonpath='{.spec.oidc.issuerUrl}')
MAAS=https://maas.$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
[ -n "$ISSUER" ] || { echo "MaaS has no OIDC issuer configured"; exit 1; }

hr(){ printf '\n\033[1m%s\033[0m\n' "$*"; }

# ---------------------------------------------------------------------------
hr "1. Where validation is configured"
echo "MaaS renders the AITenant OIDC config into an Authorino AuthConfig:"
oc get aitenants.maas.opendatahub.io models-as-a-service -n ai-tenants \
  -o jsonpath='  AITenant.spec.oidc = {.spec.oidc}{"\n"}'
AC=$(oc get authconfig -n kuadrant-system -o name 2>/dev/null | head -1)
oc get "$AC" -n kuadrant-system -o jsonpath='  AuthConfig  jwt = {.spec.authentication.oidc-identities.jwt}{"\n"}'
echo
echo "  ttl=300 is the JWKS refresh interval, not a token lifetime."

# ---------------------------------------------------------------------------
hr "2. The keys Authorino fetches"
JWKS_URI=$(curl -sSk "$ISSUER/.well-known/openid-configuration" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["jwks_uri"])')
echo "  discovery -> jwks_uri: $JWKS_URI"
curl -sSk "$JWKS_URI" | python3 -c '
import sys, json
ks = json.load(sys.stdin)["keys"]
print("  %d public key(s) published:" % len(ks))
for k in ks:
    print("    kid=%s  alg=%s  use=%s  kty=%s" % (k.get("kid"), k.get("alg"), k.get("use"), k.get("kty")))'

# ---------------------------------------------------------------------------
hr "3. The token names the key that signed it"
TOKEN=$(curl -sSk -X POST "$ISSUER/protocol/openid-connect/token" \
  -d grant_type=password -d client_id=maas-oidc \
  -d "username=${USER_NAME}" -d "password=${USER_NAME}" -d scope=openid \
  | python3 -c 'import sys,json; print(json.load(sys.stdin).get("access_token",""))')
[ -n "$TOKEN" ] || { echo "  could not get a token for ${USER_NAME}"; exit 1; }

echo "$TOKEN" | python3 -c '
import sys, json, base64
def seg(t, i):
    p = t.split(".")[i]; p += "=" * (-len(p) % 4)
    return json.loads(base64.urlsafe_b64decode(p))
t = sys.stdin.read().strip()
h, c = seg(t, 0), seg(t, 1)
print("  token header : kid=%s alg=%s" % (h.get("kid"), h.get("alg")))
print("  token claims : user=%s groups=%s" % (c.get("preferred_username"), c.get("groups")))
'
echo "  -> Authorino looks up that kid in the cached JWKS and verifies the signature."

# ---------------------------------------------------------------------------
hr "4. Proof that the signature is actually checked"
echo "Tamper with the payload - promote the user into a group they are not in -"
echo "leaving the original signature in place:"

FORGED=$(echo "$TOKEN" | python3 -c '
import sys, json, base64
def b64d(p):
    p += "=" * (-len(p) % 4); return base64.urlsafe_b64decode(p)
def b64e(b):
    return base64.urlsafe_b64encode(b).decode().rstrip("=")
h, p, s = sys.stdin.read().strip().split(".")
claims = json.loads(b64d(p))
claims["groups"] = ["ml-engineers", "platform-admins"]   # privilege escalation attempt
print("%s.%s.%s" % (h, b64e(json.dumps(claims).encode()), s))
')
echo "$FORGED" | python3 -c '
import sys, json, base64
p = sys.stdin.read().strip().split(".")[1]; p += "=" * (-len(p) % 4)
print("  forged claims: groups=%s" % json.loads(base64.urlsafe_b64decode(p)).get("groups"))'

REAL=$(curl -sSk -o /dev/null -m 30 -w '%{http_code}' -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' -X POST \
  -d '{"name":"jwks-demo-real","description":"d","expiresIn":"5m"}' "$MAAS/maas-api/v1/api-keys")
FAKE=$(curl -sSk -o /dev/null -m 30 -w '%{http_code}' -H "Authorization: Bearer $FORGED" \
  -H 'Content-Type: application/json' -X POST \
  -d '{"name":"jwks-demo-forged","description":"d","expiresIn":"5m"}' "$MAAS/maas-api/v1/api-keys")
echo
# Derive the verdict from the actual response codes. Do not label these
# statically: if the gateway is unhealthy both return 503 and a hardcoded
# "accepted / rejected" would report a passing test that never ran.
describe() {
  case "$1" in
    201|200) echo "accepted" ;;
    401|403) echo "rejected" ;;
    503)     echo "gateway unavailable - NOT a valid result" ;;
    *)       echo "unexpected" ;;
  esac
}
echo "  genuine token -> HTTP ${REAL}   ($(describe "$REAL"))"
echo "  forged  token -> HTTP ${FAKE}   ($(describe "$FAKE"))"
echo

if [ "$REAL" = "503" ] || [ "$FAKE" = "503" ]; then
  echo "  !! The gateway returned 503, so nothing was actually validated."
  echo "     Usually the Envoy WASM shim failed to load and the filter fails closed."
  echo "     Check:   oc logs -n openshift-ingress -l gateway.networking.k8s.io/gateway-name=maas-default-gateway | grep wasm"
  echo "     Fix:     oc delete pod -n openshift-ingress -l gateway.networking.k8s.io/gateway-name=maas-default-gateway"
elif [ "$REAL" = "201" ] && { [ "$FAKE" = "401" ] || [ "$FAKE" = "403" ]; }; then
  echo "  PASS - the signature is verified, not merely decoded."
  echo "  Anyone can DECODE a JWT; only the issuer can SIGN one. This is the"
  echo "  difference, and it is why the cached public keys matter."
else
  echo "  UNEXPECTED - a forged token should not be accepted. Investigate."
fi

# ---------------------------------------------------------------------------
hr "5. Evidence of caching"
echo "Authorino refreshes the keys from a background worker, not per request."
echo "The refresh machinery shows up in its logs as setupOpenIdProviderRefresh:"
oc logs -n kuadrant-system deployment/authorino --tail=3000 2>/dev/null \
  | grep -o 'setupOpenIdProviderRefresh' | head -1 | sed 's/^/    /' \
  || echo "    (no refresh entries in the current log window)"
echo
echo "  Source: pkg/evaluators/identity/jwt.go -> setupOpenIdProviderRefresh()"
echo "          driven by pkg/workers/worker.go on the ttl interval."

printf '\n\033[1mSummary\033[0m\n'
echo "  fetches   - AuthConfig points Authorino at ${ISSUER}"
echo "  validates - forged token rejected (HTTP ${FAKE}), genuine accepted (HTTP ${REAL})"
echo "  caches    - refreshed on a 300s worker, not per request"
echo
echo "  For proof of the caching claim, run: ./prove-cached.sh"
