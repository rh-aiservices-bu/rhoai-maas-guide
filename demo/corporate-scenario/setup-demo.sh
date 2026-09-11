#!/usr/bin/env bash
# Set up the corporate scenario demo: three divisions, three models, differentiated
# access and rate limits.
#
# Creates six htpasswd users across three groups:
#   corp-sales:       sales-1, sales-2
#   corp-engineering: eng-1, eng-2
#   corp-products:    prod-1, prod-2
#
# Deploys two additional simulator-backed models alongside the existing general-purpose
# model (facebook-opt-125m-simulated) and applies MaaS governance CRDs.
#
# Usage:
#   ./setup-demo.sh                         # password prompted, or set DEMO_PASSWORD
#   DEMO_PASSWORD='s3cret' ./setup-demo.sh
#
# Reverse with ./cleanup-demo.sh
set -euo pipefail

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
WORKDIR=${WORKDIR:-$(mktemp -d)}

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
HT="${WORKDIR}/corp-demo.htpasswd"
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

echo "==> Creating groups"
for grp_var in GROUP_SALES GROUP_ENG GROUP_PROD; do
  grp="${!grp_var}"
  case "$grp_var" in
    GROUP_SALES) members=("${USERS_SALES[@]}") ;;
    GROUP_ENG)   members=("${USERS_ENG[@]}") ;;
    GROUP_PROD)  members=("${USERS_PROD[@]}") ;;
  esac
  oc adm groups new "$grp" "${members[@]}" 2>/dev/null || \
    { for u in "${members[@]}"; do oc adm groups add-users "$grp" "$u" >/dev/null 2>&1 || true; done; }
  echo "  ${grp}: ${members[*]}"
done

# --- cloud-models namespace ---

echo "==> Creating cloud-models namespace"
oc apply -f "${DIR}/manifests/namespace-cloud-models.yaml"

# --- deploy new models ---

echo "==> Deploying LLMInferenceService resources"
oc apply -f "${DIR}/manifests/model-deepseek-r2.yaml"
oc apply -f "${DIR}/manifests/model-gemini-flash.yaml"

echo "==> Waiting for simulator pods (up to 3 min)..."
for ref in "deepseek-r2-llmd:llm" "gemini-flash-cloud:cloud-models"; do
  name="${ref%%:*}"; ns="${ref##*:}"
  timeout=180; elapsed=0
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
oc apply -f "${DIR}/manifests/maas-model-deepseek-r2.yaml"
oc apply -f "${DIR}/manifests/maas-model-gemini-flash.yaml"

# --- auth policies and subscriptions ---

echo "==> Applying auth policies"
oc apply -f "${DIR}/manifests/auth-policies.yaml"

echo "==> Applying subscriptions"
oc apply -f "${DIR}/manifests/subscriptions.yaml"

# --- wait for MaaSModelRef Ready ---

echo "==> Waiting for MaaSModelRef resources to reach Ready (up to 3 min)..."
for ref in "deepseek-r2-llmd:llm" "gemini-flash-cloud:cloud-models"; do
  name="${ref%%:*}"; ns="${ref##*:}"
  timeout=180; elapsed=0
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
  | jq -r '.items[] | select(.metadata.name | startswith("corp-") | not) | select(.spec.priority >= 30) | .metadata.name' 2>/dev/null || true)
if [ -n "$CONFLICTS" ]; then
  echo "  WARNING: These non-corporate subscriptions have priority >= 30 and may interfere:"
  echo "$CONFLICTS" | sed 's/^/    /'
  echo "  The corporate subscriptions also use priority 30. Higher priority wins."
fi

# --- summary ---

echo
echo "Identity providers:"
oc get oauth cluster -o jsonpath='{range .spec.identityProviders[*]}  {.name} ({.type}){"\n"}{end}'
echo
echo "Groups:"
for grp in $GROUP_SALES $GROUP_ENG $GROUP_PROD; do
  members=$(oc get group "$grp" -o jsonpath='{.users[*]}' 2>/dev/null || echo "?")
  echo "  ${grp}: ${members}"
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
