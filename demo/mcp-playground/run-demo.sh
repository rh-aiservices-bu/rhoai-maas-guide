#!/usr/bin/env bash
# Verify the MCP server is answering and print the demo runbook.
#
#   ./run-demo.sh [--namespace <ns>]
set -uo pipefail

# ANSI-C quoting so these hold real escape characters and expand correctly
# inside the heredoc at the end of this script.
GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; RED=$'\033[0;31m'; BLUE=$'\033[0;34m'; NC=$'\033[0m'
info() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[FAIL]${NC} $*"; }
step() { echo -e "${BLUE}[STEP]${NC} $*"; }

DASHBOARD_NS=redhat-ods-applications
NS=""

while [ $# -gt 0 ]; do
    case "$1" in
        --namespace) NS="$2"; shift 2 ;;
        -h|--help)   sed -n '2,5p' "$0"; exit 0 ;;
        *) err "unknown argument: $1"; exit 1 ;;
    esac
done

oc whoami >/dev/null 2>&1 || { err "not logged in to a cluster"; exit 1; }
[ -z "$NS" ] && NS=$(oc get mcpserver -A --no-headers 2>/dev/null | awk '/weather-mcp/{print $1; exit}')
[ -z "$NS" ] && { err "no weather-mcp MCPServer found - run ./setup-demo.sh first"; exit 1; }

step "Checks"

POD_STATE=$(oc get pods -n "$NS" --no-headers 2>/dev/null | awk '/weather-mcp/{print $2" "$3}' | head -1)
if [ "${POD_STATE%% *}" = "1/1" ]; then
    info "MCP server pod: $POD_STATE"
else
    err "MCP server pod not ready: ${POD_STATE:-missing}"
fi

URL=$(oc get cm gen-ai-aa-mcp-servers -n "$DASHBOARD_NS" -o json 2>/dev/null \
    | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin).get("data", {})
    for k, v in d.items():
        print(json.loads(v).get("url", "")); break
except Exception:
    print("")' 2>/dev/null)
if [ -n "$URL" ]; then
    info "registered with the playground: $URL"
else
    err "ConfigMap gen-ai-aa-mcp-servers has no usable entry - run ./setup-demo.sh"
fi

TRANSPORT=$(oc get cm gen-ai-aa-mcp-servers -n "$DASHBOARD_NS" -o json 2>/dev/null \
    | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin).get("data", {})
    for k, v in d.items():
        e = json.loads(v); print(e.get("transport") or e.get("type") or ""); break
except Exception:
    print("")' 2>/dev/null)
if [ -n "$TRANSPORT" ]; then
    info "transport declared: $TRANSPORT"
else
    warn "no transport declared - the playground will assume streamable-http and"
    warn "fail against an SSE server, reporting it as 'Authorization failed'"
fi

OGX=$(oc get dsc --no-headers 2>/dev/null | awk 'NR==1{print $1}')
[ "$(oc get dsc "$OGX" -o jsonpath='{.spec.components.ogx.managementState}' 2>/dev/null)" = "Managed" ] \
    && info "ogx: Managed" || err "ogx is not Managed - there will be no playground"

step "Live check against the MCP server"
POD=mcp-run-check
oc run "$POD" -n "$NS" --image=registry.access.redhat.com/ubi9/python-39 \
    --restart=Never --command -- sleep 60 >/dev/null 2>&1
for _ in $(seq 1 20); do
    [ "$(oc get pod "$POD" -n "$NS" --no-headers 2>/dev/null | awk '{print $3}')" = "Running" ] && break
    sleep 3
done
OUT=$(oc exec "$POD" -n "$NS" -- sh -c "curl -sS -m 6 '$URL' -H 'Accept: text/event-stream' | head -c 80" 2>/dev/null)
oc delete pod "$POD" -n "$NS" --grace-period=0 --force >/dev/null 2>&1
if echo "$OUT" | grep -q 'sessionId'; then
    info "server opened an MCP session endpoint"
else
    err "no session endpoint returned - got: ${OUT:-<nothing>}"
fi

cat <<TXT

${BLUE}=== Runbook ===${NC}

  1. Dashboard -> Gen AI studio -> Playground, select your project
  2. Settings -> Model: pick a TOOL-CALLING model and its subscription
     (the simulator cannot call tools)
  3. Settings -> Streaming: turn it OFF
  4. Settings -> MCP: the weather server appears. Click authorize and enter
     ANY value - this server has no authentication.
  5. Prompt: "What's the weather forecast for Dublin?"

  The model should answer with a tool call rather than prose.

${YELLOW}If it says 'Authorization failed'${NC}, it is almost certainly not
authorization. Read the real error:

  oc logs -n ${DASHBOARD_NS} deploy/gen-ai-ui | grep -i mcp

${YELLOW}Streaming must be off.${NC} Streamed responses through the MaaS gateway
deliver the full body and then never close; the playground reports a generic
server error. Tracked as Kuadrant wasm-shim issue #425.

TXT
