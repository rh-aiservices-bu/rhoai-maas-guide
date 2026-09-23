#!/usr/bin/env bash
# Remove what setup-demo.sh created.
#
#   ./cleanup-demo.sh [--namespace <ns>] [--disable-ogx]
#
# By default ogx and the genAiStudio flag are left enabled, since other work may
# now depend on them. Pass --disable-ogx to revert those too.
set -uo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[FAIL]${NC} $*"; }

DASHBOARD_NS=redhat-ods-applications
NS=""; DISABLE_OGX=false

while [ $# -gt 0 ]; do
    case "$1" in
        --namespace)   NS="$2"; shift 2 ;;
        --disable-ogx) DISABLE_OGX=true; shift ;;
        -h|--help)     sed -n '2,8p' "$0"; exit 0 ;;
        *) err "unknown argument: $1"; exit 1 ;;
    esac
done

oc whoami >/dev/null 2>&1 || { err "not logged in to a cluster"; exit 1; }

[ -z "$NS" ] && NS=$(oc get mcpserver -A --no-headers 2>/dev/null | awk '/weather-mcp/{print $1; exit}')

if [ -n "$NS" ]; then
    oc delete mcpserver weather-mcp -n "$NS" >/dev/null 2>&1 \
        && info "removed MCPServer weather-mcp from $NS" \
        || warn "MCPServer weather-mcp not present in $NS"
else
    warn "no weather-mcp MCPServer found"
fi

oc delete configmap gen-ai-aa-mcp-servers -n "$DASHBOARD_NS" >/dev/null 2>&1 \
    && info "removed ConfigMap gen-ai-aa-mcp-servers" \
    || warn "ConfigMap gen-ai-aa-mcp-servers not present"

if [ "$DISABLE_OGX" = true ]; then
    DSC=$(oc get datasciencecluster --no-headers 2>/dev/null | awk 'NR==1{print $1}')
    if [ -n "$DSC" ]; then
        oc patch datasciencecluster "$DSC" --type=merge \
            -p '{"spec":{"components":{"ogx":{"managementState":"Removed"}}}}' >/dev/null 2>&1 \
            && info "ogx set to Removed"
    fi
    oc patch odhdashboardconfig odh-dashboard-config -n "$DASHBOARD_NS" --type=merge \
        -p '{"spec":{"dashboardConfig":{"genAiStudio":false}}}' >/dev/null 2>&1 \
        && info "genAiStudio: false"
    warn "any existing OGXServer instances are removed with the component"
else
    info "left ogx and genAiStudio enabled (pass --disable-ogx to revert)"
fi

info "Cleanup complete."
