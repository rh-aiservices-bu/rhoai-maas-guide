#!/usr/bin/env bash
# Pre-flight for all four demos. Read-only: creates no users, applies no YAML.
#
# Checks that every identity can authenticate AND resolves the subscription its
# demo depends on - the two things that actually break between sessions.
#
# It also sends a warm-up request: maas-api returns 500 on the first call after
# an idle period while it reopens its database connection, and you do not want
# that on your first click.
#
# Usage:  ./preflight.sh
set -uo pipefail

PASS=0; FAIL=0
ok(){   printf '  \033[32mPASS\033[0m  %s\n' "$*"; PASS=$((PASS+1)); }
bad(){  printf '  \033[31mFAIL\033[0m  %s\n' "$*"; FAIL=$((FAIL+1)); }
hr(){   printf '\n\033[1m%s\033[0m\n' "$*"; }

oc whoami >/dev/null 2>&1 || { echo "not logged in to a cluster"; exit 1; }
DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
MAAS="https://maas.${DOMAIN}"
API=$(oc whoami --show-server)
ISSUER=$(oc get aitenants.maas.opendatahub.io models-as-a-service -n ai-tenants -o jsonpath='{.spec.oidc.issuerUrl}' 2>/dev/null)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
OCP_PW=${DEMO_PASSWORD:-MaaSDemo2026!}

echo "cluster: $API"
echo "MaaS:    $MAAS"

# ---------------------------------------------------------------- platform ---
hr "Platform"
[ "$(oc get maasmodelref facebook-opt-125m-simulated -n llm -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = "True" ] \
  && ok "model facebook-opt-125m-simulated is Ready" || bad "model is not Ready"
[ "$(oc get pods -n llm --no-headers 2>/dev/null | grep -c '1/1')" -ge 1 ] \
  && ok "model pod running" || bad "model pod not running"
oc get deployment maas-api -n redhat-ai-gateway-infra >/dev/null 2>&1 \
  && ok "maas-api deployed" || bad "maas-api missing"

# Warm-up: absorb the cold-start 500 so the first demo click is clean.
curl -sk -m 30 -o /dev/null -H "Authorization: Bearer $(oc whoami -t)" "$MAAS/maas-api/v1/models" 2>/dev/null
H=$(curl -sk -m 30 -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $(oc whoami -t)" "$MAAS/maas-api/v1/models")
[ "$H" = "200" ] && ok "MaaS API reachable (warm-up done)" \
  || bad "MaaS API returned HTTP ${H} — if 503, restart the gateway pods (see below)"

# Mint a key as $1 (bearer token) and report which subscription resolved.
resolved() {
  curl -sSk -m 30 -H "Authorization: Bearer $1" -H 'Content-Type: application/json' -X POST \
    -d '{"name":"preflight","description":"preflight","expiresIn":"10m"}' \
    "$MAAS/maas-api/v1/api-keys" 2>/dev/null \
    | python3 -c 'import sys,json; print(json.load(sys.stdin).get("subscription","UNRESOLVED"))' 2>/dev/null \
    || echo UNRESOLVED
}
check() {   # check <label> <token> <expected-subscription>
  local got; got=$(resolved "$2")
  [ "$got" = "$3" ] && ok "$1 -> $got" || bad "$1 -> got '${got}', expected '$3'"
}

# ------------------------------------------------- 1. user-level rate limiting ---
hr "1. user-level-rate-limiting  (OpenShift users)"
for pair in "alice:demo-alice-gold" "bob:demo-bob-throttled" "carol:demo-team-standard"; do
  U="${pair%%:*}"; WANT="${pair##*:}"
  if KUBECONFIG="$TMP/$U" oc login -u "$U" -p "$OCP_PW" --server="$API" --insecure-skip-tls-verify=true >/dev/null 2>&1; then
    check "$U" "$(KUBECONFIG="$TMP/$U" oc whoami -t)" "$WANT"
  else
    bad "$U cannot log in (password? htpasswd IdP removed?)"
  fi
done

# ------------------------------------------------------ 2. oidc authentication ---
hr "2. oidc-authentication  (Keycloak identities)"
if [ -z "$ISSUER" ]; then
  bad "MaaS has no OIDC issuer configured — run oidc-authentication/setup-oidc-demo.sh"
else
  ok "issuer configured: $ISSUER"
  for pair in "maas-user:oidc-ml-engineers" "restricted-user:oidc-data-scientists" "solo-user:solo-user-tier"; do
    U="${pair%%:*}"; WANT="${pair##*:}"
    T=$(curl -sSk -m 20 -X POST "$ISSUER/protocol/openid-connect/token" \
        -d grant_type=password -d client_id=maas-oidc \
        -d "username=$U" -d "password=$U" -d scope=openid \
        | python3 -c 'import sys,json; print(json.load(sys.stdin).get("access_token",""))' 2>/dev/null)
    [ -n "$T" ] && check "$U" "$T" "$WANT" || bad "$U could not get a token from Keycloak"
  done
fi

# -------------------------------------------------------------- 3. jwks cache ---
hr "3. jwks-cache  (signature verification)"
if [ -n "$ISSUER" ]; then
  T=$(curl -sSk -m 20 -X POST "$ISSUER/protocol/openid-connect/token" -d grant_type=password \
      -d client_id=maas-oidc -d username=maas-user -d password=maas-user -d scope=openid \
      | python3 -c 'import sys,json; print(json.load(sys.stdin).get("access_token",""))' 2>/dev/null)
  JW=$(curl -sSk -m 20 "$ISSUER/.well-known/openid-configuration" \
       | python3 -c 'import sys,json; print(json.load(sys.stdin)["jwks_uri"])' 2>/dev/null)
  N=$(curl -sSk -m 20 "$JW" | python3 -c 'import sys,json; print(len(json.load(sys.stdin)["keys"]))' 2>/dev/null)
  [ "${N:-0}" -ge 1 ] && ok "JWKS reachable (${N} keys published)" || bad "could not read the JWKS"

  FORGED=$(echo "$T" | python3 -c 'import sys,json,base64
def d(p): p += "="*(-len(p)%4); return base64.urlsafe_b64decode(p)
def e(b): return base64.urlsafe_b64encode(b).decode().rstrip("=")
h,p,s = sys.stdin.read().strip().split(".")
c = json.loads(d(p)); c["groups"] = ["platform-admins"]
print("%s.%s.%s" % (h, e(json.dumps(c).encode()), s))' 2>/dev/null)
  F=$(curl -sSk -m 30 -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $FORGED" \
      -H 'Content-Type: application/json' -X POST \
      -d '{"name":"pf","description":"d","expiresIn":"5m"}' "$MAAS/maas-api/v1/api-keys")
  { [ "$F" = "401" ] || [ "$F" = "403" ]; } && ok "forged token rejected (HTTP $F)" \
    || bad "forged token returned HTTP $F — expected 401/403"
else
  bad "skipped: no OIDC issuer configured"
fi

# --------------------------------------------------- 4. service account access ---
hr "4. service-account-access  (in-cluster workloads)"
for pair in "batch-scorer:sa-batch-scorer-tier" "report-writer:sa-report-writer-tier"; do
  SA="${pair%%:*}"; WANT="${pair##*:}"
  T=$(oc create token "$SA" -n maas-clients --duration=15m 2>/dev/null)
  [ -n "$T" ] && check "$SA" "$T" "$WANT" || bad "$SA: could not mint a token"
done
if R=$(oc get route model-client -n maas-clients -o jsonpath='{.spec.host}' 2>/dev/null) && [ -n "$R" ]; then
  A=$(curl -sk -m 30 -o /dev/null -w '%{http_code}' "https://${R}/healthz")
  [ "$A" = "200" ] && ok "in-cluster app reachable: https://${R}" || bad "app returned HTTP ${A}"
else
  bad "model-client route missing — run service-account-access/setup-demo.sh"
fi

# ------------------------------------------------------------------- summary ---
hr "Summary"
printf '  %s passed, %s failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  cat <<'TXT'

  Common fixes
    every request 503        the Envoy WASM filter failed closed:
                             oc delete pod -n openshift-ingress \
                               -l gateway.networking.k8s.io/gateway-name=maas-default-gateway
    OIDC tokens fail         Keycloak may be restarting: oc get pods -n keycloak
    a subscription is wrong  check nothing else matches that identity:
                             oc get maassubscription -n models-as-a-service \
                               -o custom-columns=NAME:.metadata.name,GROUPS:.spec.owner.groups,USERS:.spec.owner.users
TXT
  exit 1
fi
echo "  Ready to demo."
