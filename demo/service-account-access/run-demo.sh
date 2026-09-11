#!/usr/bin/env bash
# ServiceAccount access to a model, via MaaS subscriptions.
#
# No humans, no Keycloak, no external IdP: an in-cluster workload authenticates
# with its own ServiceAccount token, which MaaS validates through Kubernetes
# TokenReview.
#
#   batch-scorer   -> sa-batch-scorer-tier   (40 tokens/min)
#   report-writer  -> sa-report-writer-tier  (15 tokens/min)
#
# ACCESS is granted once for the whole namespace, by a MaaSAuthPolicy matching
# the group system:serviceaccounts:maas-clients - neither SA is named there.
# The TIER is per-workload, via a subscription matching each SA username.
#
# Usage:  ./run-demo.sh [requests_per_sa]      (default 18)
set -uo pipefail

N=${1:-18}
SA_NS=maas-clients
declare -a SAS=("batch-scorer" "report-writer")
MODEL_RESOURCE=facebook-opt-125m-simulated
MODEL_SERVED=facebook/opt-125m

oc whoami >/dev/null 2>&1 || { echo "not logged in to a cluster"; exit 1; }
MAAS=https://maas.$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
EP="${MAAS}/llm/${MODEL_RESOURCE}/v1/chat/completions"
BODY="{\"model\":\"${MODEL_SERVED}\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":4}"

echo "MaaS: $MAAS"

for SA in "${SAS[@]}"; do
  printf '\n=== %s ===\n' "system:serviceaccount:${SA_NS}:${SA}"

  TOKEN=$(oc create token "$SA" -n "$SA_NS" --duration=1h 2>/dev/null)
  [ -z "$TOKEN" ] && { echo "  could not mint a token - run ./setup-demo.sh first"; continue; }

  # The identity is in the token's `sub`, issued by the Kubernetes API - not an IdP.
  echo "$TOKEN" | python3 -c 'import sys,json,base64
p = sys.stdin.read().strip().split(".")[1]; p += "=" * (-len(p) % 4)
c = json.loads(base64.urlsafe_b64decode(p))
print("  token sub: %s" % c.get("sub"))
print("  issued by: %s" % c.get("iss"))'

  RESP=$(curl -sSk -m 30 -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
    -X POST -d "{\"name\":\"${SA}-demo\",\"description\":\"sa demo\",\"expiresIn\":\"30m\"}" \
    "${MAAS}/maas-api/v1/api-keys")
  SUB=$(echo "$RESP" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("subscription","UNRESOLVED"))' 2>/dev/null)
  KEY=$(echo "$RESP" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("key",""))' 2>/dev/null)
  echo "  resolved subscription: ${SUB}"
  [ -z "$KEY" ] && { echo "  no key issued: $(echo "$RESP" | head -c 160)"; continue; }

  # A ServiceAccount token also works directly on the model endpoint, with no
  # API key at all - usually what you want for an in-cluster workload.
  D=$(curl -sSk -m 30 -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $TOKEN" \
    -H 'Content-Type: application/json' -X POST -d "$BODY" "$EP")
  echo "  inference with the SA token directly (no API key) -> HTTP ${D}"

  ok=0; lim=0; other=0
  for _ in $(seq 1 "$N"); do
    c=$(curl -sk -m 30 -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $KEY" \
      -H 'Content-Type: application/json' -X POST -d "$BODY" "$EP")
    [ "$c" = "500" ] && c=$(curl -sk -m 30 -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $KEY" \
      -H 'Content-Type: application/json' -X POST -d "$BODY" "$EP")   # absorb cold-start 500
    case "$c" in 200) ok=$((ok+1));; 429) lim=$((lim+1));; *) other=$((other+1));; esac
  done
  printf '  burst %s -> %s ok / %s rate-limited / %s other\n' "$N" "$ok" "$lim" "$other"
done

cat <<'TXT'

Both workloads authenticated with their own ServiceAccount token, validated by
Kubernetes TokenReview. No human identity, no external identity provider, and no
credential to distribute - the token is projected into the pod by Kubernetes.

Access came from one namespace-wide MaaSAuthPolicy; the differing rate limits
came from a per-workload MaaSSubscription.
TXT
