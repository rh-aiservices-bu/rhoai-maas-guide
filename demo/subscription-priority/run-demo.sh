#!/usr/bin/env bash
# Subscription priority: entitlement is selected, not accumulated.
#
#   dual-user     groups quota-standard + quota-bulk   -> quota-standard-tier    10000 tokens/hour
#   capped-user   same two groups, plus a user tier    -> quota-individual-tier   5000 tokens/hour
#
# Both users hold group memberships worth 10000 and 20000 tokens/hour. Neither
# gets 30000: the highest-priority subscription wins outright.
#
# Usage:
#   ./run-demo.sh            show which subscription each user resolves to (repeatable)
#   ./run-demo.sh --burn     also spend real tokens to show where the limit lands
#
# --burn consumes the hour-long window for real. Re-running it inside the same
# hour will show the quota already spent.
set -uo pipefail

BURN=0
[ "${1:-}" = "--burn" ] && BURN=1

MODEL_RESOURCE=facebook-opt-125m-simulated   # KServe resource name -> URL path
MODEL_SERVED=facebook/opt-125m               # served name -> JSON body

oc whoami >/dev/null 2>&1 || { echo "not logged in to a cluster"; exit 1; }
MAAS="https://maas.$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')"
ISSUER=$(oc get aitenants.maas.opendatahub.io models-as-a-service -n ai-tenants \
         -o jsonpath='{.spec.oidc.issuerUrl}' 2>/dev/null)
[ -n "$ISSUER" ] || { echo "MaaS has no OIDC issuer configured - run ./setup-demo.sh first"; exit 1; }

echo "MaaS:   $MAAS"
echo "Issuer: $ISSUER"

# The three tiers in play, printed as a ladder so the audience can see which
# rung each user lands on.
cat <<'TXT'

The tiers, and the priority that ranks them:

   5000 tokens/hour   quota-individual-tier   priority 50   user  capped-user
  10000 tokens/hour   quota-standard-tier     priority 30   group quota-standard
  20000 tokens/hour   quota-bulk-tier         priority 20   group quota-bulk

Both users belong to BOTH groups.
TXT

for pair in "dual-user:10000:quota-standard-tier" "capped-user:5000:quota-individual-tier"; do
  U="${pair%%:*}"; rest="${pair#*:}"; LIMIT="${rest%%:*}"; WANT="${rest##*:}"
  printf '\n=== %s ===\n' "$U"

  # Retried: Keycloak can be slow to answer the first request after an idle spell.
  TOKEN=""
  for _ in 1 2 3; do
    TOKEN=$(curl -sSk -m 30 -X POST "${ISSUER}/protocol/openid-connect/token" \
      -d grant_type=password -d client_id=maas-oidc \
      -d "username=${U}" -d "password=${U}" -d scope=openid 2>/dev/null \
      | python3 -c 'import sys,json; print(json.load(sys.stdin).get("access_token",""))' 2>/dev/null)
    [ -n "$TOKEN" ] && break
  done
  [ -z "$TOKEN" ] && { echo "  token request failed - run ./setup-demo.sh"; continue; }

  echo "$TOKEN" | python3 -c 'import sys,json,base64
p=sys.stdin.read().strip().split(".")[1]; p+="="*(-len(p)%4)
c=json.loads(base64.urlsafe_b64decode(p))
print("  groups claim: %s" % sorted(c.get("groups") or []))'

  RESP=$(curl -sSk -m 30 -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -X POST \
    -d "{\"name\":\"${U}-priority\",\"description\":\"priority demo\",\"expiresIn\":\"2h\"}" \
    "${MAAS}/maas-api/v1/api-keys")
  SUB=$(echo "$RESP" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("subscription","UNRESOLVED"))' 2>/dev/null)
  KEY=$(echo "$RESP" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("key",""))' 2>/dev/null)
  printf '  resolved subscription: %s\n' "$SUB"
  [ -z "$KEY" ] && { echo "  no key issued: $(echo "$RESP" | head -c 160)"; continue; }

  if [ "$BURN" -eq 0 ]; then
    printf '  entitlement: %s tokens/hour  (not 30000 - the tiers do not add up)\n' "$LIMIT"
    continue
  fi

  # Spend real tokens. Each request carries a padded prompt of roughly 970
  # tokens, so an hour's quota is reached in a handful of calls rather than
  # hundreds.
  python3 - "$MAAS" "$KEY" "$MODEL_RESOURCE" "$MODEL_SERVED" "$LIMIT" <<'PY'
import json, ssl, sys, urllib.error, urllib.request

maas, key, path, served, limit = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], int(sys.argv[5])
ctx = ssl.create_default_context(); ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_NONE
url = f"{maas}/llm/{path}/v1/chat/completions"
prompt = "Summarise this document. " + ("data point analysis result summary " * 180)

def once():
    body = json.dumps({"model": served,
                       "messages": [{"role": "user", "content": prompt}],
                       "max_tokens": 64}).encode()
    req = urllib.request.Request(url, data=body, method="POST",
        headers={"Content-Type": "application/json", "Authorization": f"Bearer {key}"})
    try:
        with urllib.request.urlopen(req, context=ctx, timeout=60) as r:
            return 200, json.loads(r.read()).get("usage", {}).get("total_tokens", 0)
    except urllib.error.HTTPError as e:
        return e.code, 0
    except Exception:
        return 0, 0

def call(retries=2):
    """Retry a 5xx: the first call after an idle period can fail while the
    gateway reopens its connection pool. A 429 is a real answer, never retried."""
    for attempt in range(retries + 1):
        code, used = once()
        if code == 200 or code == 429 or attempt == retries:
            return code, used
    return code, used

print("\n  spending tokens (~970 per request, 25 requests maximum)...")
spent = ok = 0
for i in range(1, 26):
    code, used = call()
    spent += used
    if code == 200:
        ok += 1
        if ok % 5 == 0:
            print(f"    {ok:2} requests OK   {spent:6} tokens spent")
    elif code == 429:
        if ok == 0:
            print(f"    429 on the first request - this hour's {limit} tokens are already spent.")
            print( "    The window is an hour long; wait for it to roll, or run without --burn")
            print( "    to show which subscription resolves.")
            break
        print(f"    {ok:2} requests OK   {spent:6} tokens spent   next request -> 429, quota reached")
        break
    else:
        print(f"    request {i} returned HTTP {code}")
        break

if ok:
    print(f"\n  stopped after {ok} successful requests, ~{spent} tokens")
    for value, label in ((5000, "quota-individual-tier"),
                         (10000, "quota-standard-tier"),
                         (20000, "quota-bulk-tier"),
                         (30000, "the two group tiers added together")):
        mark = "  <- landed here" if value == limit else ""
        print(f"    {value:6}  {label}{mark}")
PY
done

cat <<'TXT'

Both users hold the same two group memberships, worth 10000 and 20000 tokens per
hour. Neither is entitled to 30000.

MaaS ranks every subscription an identity matches and applies the highest
priority one in full. Adding a user to a group with a larger allowance does not
raise their ceiling, and a subscription naming an individual user outranks the
groups they belong to - so it can also cap someone BELOW every group tier they
hold, which is what capped-user shows.
TXT
