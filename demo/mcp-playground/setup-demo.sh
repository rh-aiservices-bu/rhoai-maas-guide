#!/usr/bin/env bash
# Deploy a sample MCP server and register it with the RHOAI gen AI playground.
#
#   ./setup-demo.sh [--namespace <ns>] [--name <display-name>]
#
# Defaults to the namespace holding an OGXServer, so the playground can reach
# the MCP server without a NetworkPolicy. Idempotent.
set -uo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'
info() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[FAIL]${NC} $*"; }
step() { echo -e "${BLUE}[STEP]${NC} $*"; }

DASHBOARD_NS=redhat-ods-applications
IMAGE=quay.io/rh-aiservices-bu/mcp-weather:0.1.0-amd64
# The image hardcodes 3001 and serves /sse - it ignores MCP_PORT.
PORT=3001
MCP_PATH=/sse
NS=""; DISPLAY_NAME="Weather-MCP-Server"

while [ $# -gt 0 ]; do
    case "$1" in
        --namespace) NS="$2"; shift 2 ;;
        --name)      DISPLAY_NAME="$2"; shift 2 ;;
        -h|--help)   sed -n '2,8p' "$0"; exit 0 ;;
        *) err "unknown argument: $1"; exit 1 ;;
    esac
done

oc whoami >/dev/null 2>&1 || { err "not logged in to a cluster"; exit 1; }

oc get crd mcpservers.mcp.x-k8s.io >/dev/null 2>&1 || {
    err "MCPServer CRD not found - enable the MCP Lifecycle Operator first:"
    echo "  oc patch datasciencecluster default-dsc --type=merge \\"
    echo "    -p '{\"spec\":{\"components\":{\"mcplifecycleoperator\":{\"managementState\":\"Managed\"}}}}'"
    exit 1
}

step "1/4 Enabling the OGX component (playground backend)"
DSC=$(oc get datasciencecluster --no-headers 2>/dev/null | awk 'NR==1{print $1}')
[ -z "$DSC" ] && { err "no DataScienceCluster found"; exit 1; }
if [ "$(oc get dsc "$DSC" -o jsonpath='{.spec.components.ogx.managementState}' 2>/dev/null)" = "Managed" ]; then
    info "ogx already Managed"
else
    oc patch datasciencecluster "$DSC" --type=merge \
        -p '{"spec":{"components":{"ogx":{"managementState":"Managed"}}}}' >/dev/null 2>&1 \
        && info "ogx set to Managed"
    for _ in $(seq 1 30); do
        [ "$(oc get ogx -A --no-headers 2>/dev/null | awk 'NR==1{print $2}')" = "True" ] && break
        sleep 5
    done
fi
warn "if this cluster is GitOps-managed the DSC change may be reverted - put it in git"

step "2/4 Enabling the Gen AI studio dashboard flag"
oc patch odhdashboardconfig odh-dashboard-config -n "$DASHBOARD_NS" --type=merge \
    -p '{"spec":{"dashboardConfig":{"genAiStudio":true}}}' >/dev/null 2>&1 \
    && info "genAiStudio: true"

# The playground's OGX server must reach the MCP server. Putting them in the
# same namespace avoids needing a NetworkPolicy at all.
if [ -z "$NS" ]; then
    NS=$(oc get ogxserver -A --no-headers 2>/dev/null | awk 'NR==1{print $1}')
    [ -z "$NS" ] && NS=llm
fi
info "namespace: $NS"

step "3/4 Deploying the sample weather MCP server"
cat <<YAML | oc apply -f - >/dev/null 2>&1
apiVersion: mcp.x-k8s.io/v1alpha1
kind: MCPServer
metadata:
  name: weather-mcp
  namespace: ${NS}
spec:
  source:
    type: ContainerImage
    containerImage:
      ref: ${IMAGE}
  config:
    port: ${PORT}
    path: ${MCP_PATH}
  mcp:
    stateless: true
  runtime:
    replicas: 1
    resources:
      requests: {cpu: 50m, memory: 128Mi}
      limits:   {cpu: 300m, memory: 256Mi}
YAML
info "MCPServer weather-mcp applied ($IMAGE)"

for _ in $(seq 1 40); do
    READY=$(oc get pods -n "$NS" -l app=mcp-server --no-headers 2>/dev/null | awk '/weather-mcp/{print $2}' | head -1)
    [ "$READY" = "1/1" ] && break
    sleep 5
done
oc get pods -n "$NS" --no-headers 2>/dev/null | awk '/weather-mcp/{print "  pod: "$1" "$2" "$3}'

URL="http://weather-mcp.${NS}.svc.cluster.local:${PORT}${MCP_PATH}"

step "4/4 Registering it with the playground"
# The playground reads MCP servers from this ConfigMap, NOT from
# MCPServerRegistration objects. transport/type must be declared or the
# playground assumes streamable-http, POSTs at the SSE endpoint and 404s -
# which the UI reports as "Authorization failed".
PAYLOAD=$(python3 - "$URL" <<'PY'
import json, sys
print(json.dumps({
    "url": sys.argv[1],
    "description": "Weather MCP server - forecasts and alerts. Sample server, no credentials required.",
    "transport": "sse",
    "type": "sse",
}, indent=2))
PY
)
oc create configmap gen-ai-aa-mcp-servers -n "$DASHBOARD_NS" \
    --from-literal="$DISPLAY_NAME=$PAYLOAD" --dry-run=client -o yaml \
    | oc apply -f - >/dev/null 2>&1 \
    && info "registered '$DISPLAY_NAME' -> $URL"

echo
step "Verifying the server answers"
POD=mcp-reach-check
oc run "$POD" -n "$NS" --image=registry.access.redhat.com/ubi9/python-39 \
    --restart=Never --command -- sleep 90 >/dev/null 2>&1
for _ in $(seq 1 20); do
    [ "$(oc get pod "$POD" -n "$NS" --no-headers 2>/dev/null | awk '{print $3}')" = "Running" ] && break
    sleep 3
done
OUT=$(oc exec "$POD" -n "$NS" -- sh -c "curl -sS -m 6 '$URL' -H 'Accept: text/event-stream' | head -c 60" 2>/dev/null)
oc delete pod "$POD" -n "$NS" --grace-period=0 --force >/dev/null 2>&1

if echo "$OUT" | grep -q 'sessionId'; then
    info "MCP server answering on $URL"
else
    err "no MCP session endpoint returned from $URL"
    warn "got: ${OUT:-<nothing>}"
fi

echo
info "Setup complete. Next: ./run-demo.sh"
warn "In the playground, turn Streaming OFF - streamed responses through the MaaS"
warn "gateway never close and surface as a generic server error (wasm-shim #425)."
