#!/usr/bin/env bash
# Set up the Fed Aura Capital demo: seven divisions, six fake models, hourly caps.
#
# A fully working, CPU-only replica of the Fed Aura Capital setup. Every "model"
# is the llm-d inference simulator with a convincing name - no real models, no GPUs.
#
# Creates 14 htpasswd users across seven groups (2 per division):
#   fedaura-sales:      sales-1, sales-2
#   fedaura-branch:     branch-1, branch-2
#   fedaura-credit:     credit-1, credit-2
#   fedaura-developers: dev-1, dev-2
#   fedaura-it:         it-1, it-2
#   fedaura-risk:       risk-1, risk-2
#   fedaura-marketing:  marketing-1, marketing-2
#
# Deploys six simulator-backed models (3 on-prem in llm, 3 cloud in cloud-models)
# and applies the MaaS governance CRDs (model refs, auth policies, subscriptions).
#
# Usage:
#   ./setup-demo.sh                         # password prompted, or set DEMO_PASSWORD
#   DEMO_PASSWORD='s3cret' ./setup-demo.sh
#
# Reverse with ./cleanup-demo.sh
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GROUP_SALES=fedaura-sales
GROUP_BRANCH=fedaura-branch
GROUP_CREDIT=fedaura-credit
GROUP_DEVELOPERS=fedaura-developers
GROUP_IT=fedaura-it
GROUP_RISK=fedaura-risk
GROUP_MARKETING=fedaura-marketing

USERS_SALES=(sales-1 sales-2)
USERS_BRANCH=(branch-1 branch-2)
USERS_CREDIT=(credit-1 credit-2)
USERS_DEVELOPERS=(dev-1 dev-2)
USERS_IT=(it-1 it-2)
USERS_RISK=(risk-1 risk-2)
USERS_MARKETING=(marketing-1 marketing-2)
ALL_USERS=("${USERS_SALES[@]}" "${USERS_BRANCH[@]}" "${USERS_CREDIT[@]}" \
  "${USERS_DEVELOPERS[@]}" "${USERS_IT[@]}" "${USERS_RISK[@]}" "${USERS_MARKETING[@]}")

SECRET=fedaura-htpasswd
IDP=fedaura-demo
WORKDIR=${WORKDIR:-$(mktemp -d)}

# Models: name:namespace pairs
MODELS="gpt-oss-120b:llm kimi-k3:llm nemotron-lightning:llm claude-opus-5-1:cloud-models gemini-3-pro:cloud-models terra-large-context:cloud-models"

# --- prerequisites ---

command -v htpasswd >/dev/null || { echo "htpasswd not found (install httpd-tools / apache2-utils)"; exit 1; }
command -v jq >/dev/null || { echo "jq not found"; exit 1; }
oc whoami >/dev/null 2>&1 || { echo "not logged in to a cluster"; exit 1; }

echo "==> Checking existing setup"
if ! oc get maasmodelref facebook-opt-125m-simulated -n llm >/dev/null 2>&1; then
  echo "ERROR: facebook-opt-125m-simulated MaaSModelRef not found in namespace llm."
  echo "Run setup-maas.sh --model simulator first."
  exit 1
fi

PHASE=$(oc get maasmodelref facebook-opt-125m-simulated -n llm -o jsonpath='{.status.phase}' 2>/dev/null || echo "unknown")
if [ "$PHASE" != "Ready" ]; then
  echo "WARNING: facebook-opt-125m-simulated phase is '${PHASE}', not Ready."
  echo "The demo may not work correctly. Continue anyway? (Ctrl+C to abort)"
  sleep 3
fi

# --- password ---

if [ -z "${DEMO_PASSWORD:-}" ]; then
  read -rsp "Password for demo users: " DEMO_PASSWORD; echo
fi
[ -n "$DEMO_PASSWORD" ] || { echo "empty password"; exit 1; }

# --- oauth backup ---

echo "==> Backing up oauth/cluster to ${WORKDIR}/oauth-cluster.backup.yaml"
oc get oauth cluster -o yaml > "${WORKDIR}/oauth-cluster.backup.yaml"

# --- htpasswd users ---

echo "==> Generating htpasswd for: ${ALL_USERS[*]}"
HT="${WORKDIR}/fedaura-demo.htpasswd"
htpasswd -c -B -b "$HT" "${ALL_USERS[0]}" "$DEMO_PASSWORD" >/dev/null 2>&1
for u in "${ALL_USERS[@]:1}"; do htpasswd -B -b "$HT" "$u" "$DEMO_PASSWORD" >/dev/null 2>&1; done

echo "==> Creating secret ${SECRET} in openshift-config"
oc create secret generic "$SECRET" --from-file=htpasswd="$HT" -n openshift-config \
  --dry-run=client -o yaml | oc apply -f -

if oc get oauth cluster -o jsonpath='{.spec.identityProviders[*].name}' | tr ' ' '\n' | grep -qx "$IDP"; then
  echo "==> Identity provider ${IDP} already present, skipping"
else
  echo "==> Adding identity provider ${IDP} (additive - existing providers untouched)"
  oc patch oauth cluster --type=json -p "[{\"op\":\"add\",\"path\":\"/spec/identityProviders/-\",\"value\":{\"name\":\"${IDP}\",\"mappingMethod\":\"claim\",\"type\":\"HTPasswd\",\"htpasswd\":{\"fileData\":{\"name\":\"${SECRET}\"}}}}]"
fi

# --- groups ---

create_group() {
  local grp="$1"; shift
  oc adm groups new "$grp" "$@" 2>/dev/null || \
    { for u in "$@"; do oc adm groups add-users "$grp" "$u" >/dev/null 2>&1 || true; done; }
  echo "  ${grp}: $*"
}
echo "==> Creating groups"
create_group "$GROUP_SALES"      "${USERS_SALES[@]}"
create_group "$GROUP_BRANCH"     "${USERS_BRANCH[@]}"
create_group "$GROUP_CREDIT"     "${USERS_CREDIT[@]}"
create_group "$GROUP_DEVELOPERS" "${USERS_DEVELOPERS[@]}"
create_group "$GROUP_IT"         "${USERS_IT[@]}"
create_group "$GROUP_RISK"       "${USERS_RISK[@]}"
create_group "$GROUP_MARKETING"  "${USERS_MARKETING[@]}"

# --- cloud-models namespace ---

echo "==> Creating cloud-models namespace"
oc apply -f "${DIR}/manifests/namespace-cloud-models.yaml"

# --- deploy fake models ---

echo "==> Deploying LLMInferenceService resources"
oc apply -f "${DIR}/manifests/models-onprem.yaml"
oc apply -f "${DIR}/manifests/models-cloud.yaml"

echo "==> Waiting for simulator pods (up to 5 min)..."
for ref in $MODELS; do
  name="${ref%%:*}"; ns="${ref##*:}"
  timeout=300; elapsed=0
  while true; do
    ready=$(oc get pods -n "$ns" -l "app.kubernetes.io/name=${name}" --no-headers 2>/dev/null \
      | grep -c "Running" || true)
    if [ "$ready" -ge 1 ]; then
      echo "  ${ns}/${name}: simulator pod Running"
      break
    fi
    if [ "$elapsed" -ge "$timeout" ]; then
      echo "  WARNING: timeout waiting for ${name} pod in ${ns}"
      break
    fi
    sleep 5; elapsed=$((elapsed+5))
  done
done

# --- MaaSModelRef ---

echo "==> Applying MaaSModelRef resources"
oc apply -f "${DIR}/manifests/maas-models.yaml"

# --- auth policies and subscriptions ---

echo "==> Applying auth policies"
oc apply -f "${DIR}/manifests/auth-policies.yaml"

echo "==> Applying subscriptions"
oc apply -f "${DIR}/manifests/subscriptions.yaml"

# --- wait for MaaSModelRef Ready ---

echo "==> Waiting for MaaSModelRef resources to reach Ready (up to 5 min)..."
for ref in $MODELS; do
  name="${ref%%:*}"; ns="${ref##*:}"
  timeout=300; elapsed=0
  while true; do
    phase=$(oc get maasmodelref "$name" -n "$ns" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    if [ "$phase" = "Ready" ]; then
      echo "  ${name} (${ns}): Ready"
      break
    fi
    if [ "$elapsed" -ge "$timeout" ]; then
      echo "  WARNING: ${name} (${ns}) still in phase '${phase}' after ${timeout}s"
      echo "  Check: oc get maasmodelref ${name} -n ${ns} -o yaml"
      break
    fi
    sleep 5; elapsed=$((elapsed+5))
  done
done

# --- priority check ---

echo "==> Checking for priority conflicts"
CONFLICTS=$(oc get maassubscription -n models-as-a-service -o json 2>/dev/null \
  | jq -r '.items[] | select(.metadata.name | startswith("fedaura-") | not) | select(.spec.priority >= 30) | .metadata.name' 2>/dev/null || true)
if [ -n "$CONFLICTS" ]; then
  echo "  WARNING: These non-Fed-Aura subscriptions have priority >= 30 and may interfere:"
  echo "$CONFLICTS" | sed 's/^/    /'
  echo "  The Fed Aura subscriptions also use priority 30. Higher priority wins."
fi

# --- summary ---

echo
echo "Identity providers:"
oc get oauth cluster -o jsonpath='{range .spec.identityProviders[*]}  {.name} ({.type}){"\n"}{end}'
echo
echo "Groups:"
for grp in "$GROUP_SALES" "$GROUP_BRANCH" "$GROUP_CREDIT" "$GROUP_DEVELOPERS" "$GROUP_IT" "$GROUP_RISK" "$GROUP_MARKETING"; do
  oc get group "$grp" -o jsonpath='{.metadata.name}{"\n"}' 2>/dev/null || true
done
echo
echo "Models:"
oc get maasmodelref -A --no-headers 2>/dev/null | awk '{printf "  %-35s %-20s %s\n", $2, $1, $5}'
echo
echo "Subscriptions:"
oc get maassubscription -n models-as-a-service --no-headers 2>/dev/null | awk '{printf "  %-25s prio=%s\n", $1, $4}'
echo
echo "Setup complete. The oauth pods restart before new users can log in (usually under a minute)."
echo "Backup and htpasswd kept in: ${WORKDIR}"
echo
echo "Next: ./run-demo.sh"
