#!/usr/bin/env bash
#
# cleanup-maas.sh - Tear down MaaS (Models as a Service) from RHOAI
#
# Reverses setup-maas.sh in reverse order:
#   Phase 1: External models  - ExternalModel CRs, secrets, namespace
#   Phase 2: Observability    - telemetry, COO, OpenTelemetry, Tempo operators
#   Phase 3: Models           - LLMInferenceService, MaaS CRs, llm namespace
#   Phase 4: RHOAI config     - DataScienceCluster, DSCInitialization, Dashboard
#   Phase 5: MaaS platform    - PostgreSQL, secrets
#   Phase 6: Platform config  - Gateway, Kuadrant, UWM, MetalLB
#   Phase 7: Operators        - subscriptions, CSVs, operator namespaces
#
# Each phase checks if resources exist before deleting (idempotent).
#
# Usage:
#   ./scripts/cleanup-maas.sh [OPTIONS]
#
# Options:
#   --from-phase <N>     Start from phase N (1-7, default: 1)
#   --keep-operators     Skip Phase 7 (keep operators installed)
#   --dry-run            Preview without deleting
#   --yes                Skip confirmation prompt
#   -h, --help           Show this help message
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUIDE_DIR="$SCRIPT_DIR/.."
MANIFESTS_DIR="$GUIDE_DIR/manifests"
NAMESPACE=redhat-ods-applications

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_step()  { echo -e "${BLUE}[STEP]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_phase() { echo -e "\n${BOLD}${RED}════════════════════════════════════════════${NC}"; echo -e "${BOLD}${RED}  Cleanup Phase $1: $2${NC}"; echo -e "${BOLD}${RED}════════════════════════════════════════════${NC}"; }

FROM_PHASE=1
KEEP_OPERATORS=false
DRY_RUN=false
AUTO_YES=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --from-phase) FROM_PHASE="$2"; shift 2 ;;
        --keep-operators) KEEP_OPERATORS=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        --yes) AUTO_YES=true; shift ;;
        -h|--help)
            cat <<'EOF'
Usage: cleanup-maas.sh [OPTIONS]

Tear down MaaS from RHOAI. Reverses setup-maas.sh in reverse order.
Each phase checks if resources exist before deleting (idempotent).

Options:
  --from-phase <N>     Start from phase N (1-7, default: 1)
  --keep-operators     Skip Phase 7 (keep operators installed)
  --dry-run            Preview without deleting
  --yes                Skip confirmation prompt
  -h, --help           Show this help message

Phases:
  1  External models    ExternalModel CRs, provider secrets, external-models namespace
  2  Observability      Telemetry, COO, OpenTelemetry, Tempo operators
  3  Models             LLMInferenceService, MaaS CRs, llm namespace
  4  RHOAI config       DataScienceCluster, DSCInitialization, Dashboard config
  5  MaaS platform      PostgreSQL deployment, PVC, secrets
  6  Platform config    Gateway, GatewayClass, Kuadrant, UWM, MetalLB
  7  Operators          Subscriptions, CSVs, operator namespaces
EOF
            exit 0
            ;;
        *) log_error "Unknown option: $1"; exit 1 ;;
    esac
done

run_cmd() {
    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY RUN] $*"
    else
        "$@"
    fi
}

should_run() { [ "$FROM_PHASE" -le "$1" ]; }

delete_if_exists() {
    local resource="$1"
    local name="$2"
    local namespace="${3:-}"

    local ns_flag=""
    [ -n "$namespace" ] && ns_flag="-n $namespace"

    if oc get "$resource" "$name" $ns_flag &>/dev/null; then
        log_info "  Deleting $resource/$name${namespace:+ in $namespace}..."
        run_cmd oc delete "$resource" "$name" $ns_flag --ignore-not-found --timeout=120s
    else
        log_info "  $resource/$name${namespace:+ in $namespace} not found, skipping"
    fi
}

delete_namespace() {
    local ns="$1"
    if oc get namespace "$ns" &>/dev/null; then
        log_info "  Deleting namespace $ns..."
        run_cmd oc delete namespace "$ns" --ignore-not-found --timeout=300s
    else
        log_info "  Namespace $ns not found, skipping"
    fi
}

delete_all_in_ns() {
    local resource="$1"
    local namespace="$2"

    local count
    count=$(oc get "$resource" -n "$namespace" --no-headers 2>/dev/null | wc -l | tr -d ' ' || echo "0")
    if [ "$count" -gt 0 ]; then
        log_info "  Deleting all $resource in $namespace ($count found)..."
        run_cmd oc delete "$resource" --all -n "$namespace" --ignore-not-found --timeout=120s
    fi
}

# =============================================================================
# Preflight
# =============================================================================
if ! oc whoami &>/dev/null; then
    log_error "Not logged into OpenShift cluster. Run: oc login <cluster>"
    exit 1
fi
log_info "Cluster: $(oc whoami --show-server)"
log_info "User:    $(oc whoami)"

if [ "$DRY_RUN" = true ]; then
    log_warn "DRY RUN mode - no resources will be deleted"
    echo ""
fi

if [ "$AUTO_YES" = false ] && [ "$DRY_RUN" = false ]; then
    echo ""
    echo -e "${RED}${BOLD}WARNING: This will delete MaaS resources from the cluster.${NC}"
    echo -e "Cluster: ${BOLD}$(oc whoami --show-server)${NC}"
    echo -e "Phases to run: ${FROM_PHASE}-$([ "$KEEP_OPERATORS" = true ] && echo "6" || echo "7")"
    echo ""
    read -rp "Are you sure? (y/N) " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_info "Aborted."
        exit 0
    fi
fi

# =============================================================================
# Phase 1: External Models
# =============================================================================
if should_run 1; then
    log_phase 1 "External Models"

    for provider in openai gemini bedrock; do
        if oc get namespace external-models &>/dev/null; then
            delete_all_in_ns "externalmodel" "external-models"
        fi
    done

    # MaaS governance CRs for external models
    for cr in maasauthpolicy maassubscription; do
        for name in $(oc get "$cr" -n models-as-a-service --no-headers -o custom-columns='NAME:.metadata.name' 2>/dev/null | grep -E 'openai|gemini|bedrock' || true); do
            log_info "  Deleting $cr/$name in models-as-a-service..."
            run_cmd oc delete "$cr" "$name" -n models-as-a-service --ignore-not-found
        done
    done

    for name in $(oc get maasmodelref -n external-models --no-headers -o custom-columns='NAME:.metadata.name' 2>/dev/null || true); do
        log_info "  Deleting maasmodelref/$name in external-models..."
        run_cmd oc delete maasmodelref "$name" -n external-models --ignore-not-found
    done

    # Provider secrets
    for secret in openai-api-key gemini-api-key bedrock-api-key; do
        if oc get secret "$secret" -n external-models &>/dev/null; then
            log_info "  Deleting secret/$secret in external-models..."
            run_cmd oc delete secret "$secret" -n external-models --ignore-not-found
        fi
    done

    delete_namespace "external-models"
    log_info "External models cleanup complete"
fi

# =============================================================================
# Phase 2: Observability
# =============================================================================
if should_run 2; then
    log_phase 2 "Observability"

    # Telemetry CRs
    if oc get namespace openshift-ingress &>/dev/null; then
        for cr in telemetrypolicy telemetry; do
            delete_all_in_ns "$cr" "openshift-ingress" 2>/dev/null || true
        done
    fi

    # COO operator
    if oc get csv -n openshift-cluster-observability-operator --no-headers 2>/dev/null | grep -q "cluster-observability-operator"; then
        log_info "  Removing COO operator..."
        delete_if_exists subscription cluster-observability-operator openshift-cluster-observability-operator
        for csv in $(oc get csv -n openshift-cluster-observability-operator --no-headers -o custom-columns='NAME:.metadata.name' 2>/dev/null | grep cluster-observability-operator || true); do
            run_cmd oc delete csv "$csv" -n openshift-cluster-observability-operator --ignore-not-found
        done
        delete_namespace "openshift-cluster-observability-operator"
    else
        log_info "  COO operator not found, skipping"
    fi

    # OpenTelemetry operator
    if oc get csv -n openshift-opentelemetry-operator --no-headers 2>/dev/null | grep -q "opentelemetry"; then
        log_info "  Removing OpenTelemetry operator..."
        delete_if_exists subscription opentelemetry-product openshift-opentelemetry-operator
        for csv in $(oc get csv -n openshift-opentelemetry-operator --no-headers -o custom-columns='NAME:.metadata.name' 2>/dev/null | grep opentelemetry || true); do
            run_cmd oc delete csv "$csv" -n openshift-opentelemetry-operator --ignore-not-found
        done
        delete_namespace "openshift-opentelemetry-operator"
    else
        log_info "  OpenTelemetry operator not found, skipping"
    fi

    # Tempo operator
    if oc get csv -n openshift-tempo-operator --no-headers 2>/dev/null | grep -q "tempo"; then
        log_info "  Removing Tempo operator..."
        delete_if_exists subscription tempo-product openshift-tempo-operator
        for csv in $(oc get csv -n openshift-tempo-operator --no-headers -o custom-columns='NAME:.metadata.name' 2>/dev/null | grep tempo || true); do
            run_cmd oc delete csv "$csv" -n openshift-tempo-operator --ignore-not-found
        done
        delete_namespace "openshift-tempo-operator"
    else
        log_info "  Tempo operator not found, skipping"
    fi

    # Redis for Limitador persistence
    if oc get namespace redis-limitador >/dev/null 2>&1; then
        log_info "  Removing Redis for Limitador..."
        # Revert Limitador to in-memory storage
        if oc get limitador limitador -n kuadrant-system >/dev/null 2>&1; then
            run_cmd oc patch limitador limitador -n kuadrant-system --type=json \
                -p '[{"op":"remove","path":"/spec/storage"}]' 2>/dev/null || true
        fi
        run_cmd oc delete -k "$MANIFESTS_DIR/07-observability/redis/" --ignore-not-found 2>/dev/null || true
        delete_namespace "redis-limitador"
    else
        log_info "  Redis for Limitador not found, skipping"
    fi

    log_info "Observability cleanup complete"
fi

# =============================================================================
# Phase 3: Models
# =============================================================================
if should_run 3; then
    log_phase 3 "Models"

    # MaaS governance CRs (auth policies and subscriptions in models-as-a-service)
    if oc get namespace models-as-a-service &>/dev/null; then
        for cr in maassubscription maasauthpolicy; do
            delete_all_in_ns "$cr" "models-as-a-service"
        done
    fi

    # MaaSModelRef in model namespace
    if oc get namespace llm &>/dev/null; then
        delete_all_in_ns "maasmodelref" "llm"
        delete_all_in_ns "llminferenceservice" "llm"
        delete_namespace "llm"
    else
        log_info "  Namespace llm not found, skipping"
    fi

    log_info "Models cleanup complete"
fi

# =============================================================================
# Phase 4: RHOAI Configuration
# =============================================================================
if should_run 4; then
    log_phase 4 "RHOAI Configuration"

    delete_if_exists odhdashboardconfig odh-dashboard-config "$NAMESPACE"
    delete_if_exists datasciencecluster default-dsc ""
    delete_if_exists dscinitialization default-dsci ""

    log_info "RHOAI configuration cleanup complete"
fi

# =============================================================================
# Phase 5: MaaS Platform
# =============================================================================
if should_run 5; then
    log_phase 5 "MaaS Platform"

    delete_if_exists deployment postgres "$NAMESPACE"
    delete_if_exists service postgres "$NAMESPACE"
    delete_if_exists pvc postgres-data "$NAMESPACE"
    delete_if_exists secret postgres-creds "$NAMESPACE"
    delete_if_exists secret maas-db-config "$NAMESPACE"

    # Clean up 3.5+ mirrored secret and namespace
    if oc get secret maas-db-config -n redhat-ai-gateway-infra &>/dev/null 2>&1; then
        delete_if_exists secret maas-db-config redhat-ai-gateway-infra
    fi

    log_info "MaaS platform cleanup complete"
fi

# =============================================================================
# Phase 6: Platform Configuration
# =============================================================================
if should_run 6; then
    log_phase 6 "Platform Configuration"

    # Gateway and Route
    delete_if_exists route maas-default-gateway-https openshift-ingress
    delete_if_exists gateway maas-default-gateway openshift-ingress
    delete_if_exists configmap maas-gateway-options openshift-ingress
    delete_if_exists gatewayclass openshift-default ""

    # Kuadrant
    if oc get namespace kuadrant-system &>/dev/null; then
        delete_if_exists kuadrant kuadrant kuadrant-system
        # Wait for the Kuadrant CR finalizers to clean up
        if [ "$DRY_RUN" = false ]; then
            log_info "  Waiting for Kuadrant cleanup (30s)..."
            sleep 10
        fi
        delete_if_exists service authorino-authorino-authorization kuadrant-system
        delete_namespace "kuadrant-system"
    else
        log_info "  Namespace kuadrant-system not found, skipping"
    fi

    # UWM - remove enableUserWorkload from cluster-monitoring-config
    if oc get configmap cluster-monitoring-config -n openshift-monitoring &>/dev/null; then
        log_info "  Removing enableUserWorkload from cluster-monitoring-config..."
        if [ "$DRY_RUN" = false ]; then
            oc patch configmap cluster-monitoring-config -n openshift-monitoring \
                --type=merge -p '{"data":{"config.yaml":""}}' 2>/dev/null || true
        else
            log_info "[DRY RUN] Would patch cluster-monitoring-config"
        fi
    fi

    # Remove gateway-access labels from both possible namespaces
    if [ "$DRY_RUN" = false ]; then
        oc label namespace "$NAMESPACE" maas.opendatahub.io/gateway-access- 2>/dev/null || true
        oc label namespace redhat-ai-gateway-infra maas.opendatahub.io/gateway-access- 2>/dev/null || true
    else
        log_info "[DRY RUN] Would remove gateway-access label from $NAMESPACE and redhat-ai-gateway-infra"
    fi

    # MetalLB (if installed by setup-maas.sh)
    if oc get namespace metallb-system &>/dev/null; then
        log_info "  Removing MetalLB resources..."
        delete_if_exists l2advertisement maas-advertisement metallb-system
        delete_if_exists ipaddresspool maas-pool metallb-system
        delete_if_exists metallb metallb metallb-system
        delete_if_exists subscription metallb-operator metallb-system
        for csv in $(oc get csv -n metallb-system --no-headers -o custom-columns='NAME:.metadata.name' 2>/dev/null | grep metallb || true); do
            run_cmd oc delete csv "$csv" -n metallb-system --ignore-not-found
        done
        delete_namespace "metallb-system"
    else
        log_info "  MetalLB not found, skipping"
    fi

    log_info "Platform configuration cleanup complete"
fi

# =============================================================================
# Phase 7: Operators
# =============================================================================
if should_run 7 && [ "$KEEP_OPERATORS" = false ]; then
    log_phase 7 "Operators"

    # Delete CRs before operators so finalizers can run
    # Tenant CR has a finalizer that only the RHOAI operator can remove - delete it first
    if oc get namespace models-as-a-service &>/dev/null; then
        for tenant in $(oc get tenants.maas.opendatahub.io -n models-as-a-service --no-headers -o custom-columns='NAME:.metadata.name' 2>/dev/null || true); do
            log_info "  Deleting tenant/$tenant in models-as-a-service..."
            run_cmd oc delete tenant "$tenant" -n models-as-a-service --ignore-not-found --timeout=30s 2>/dev/null || \
                run_cmd oc patch tenant "$tenant" -n models-as-a-service --type=merge -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true
        done
    fi

    # RHCL / Kuadrant operator (subscription is in openshift-operators, shared namespace)
    log_info "  Removing RHCL operator..."
    delete_if_exists subscription rhcl-operator openshift-operators
    for csv in $(oc get csv -n openshift-operators --no-headers -o custom-columns='NAME:.metadata.name' 2>/dev/null | grep -E 'rhcl-operator|authorino-operator|limitador-operator|dns-operator' || true); do
        log_info "  Deleting CSV $csv..."
        run_cmd oc delete csv "$csv" -n openshift-operators --ignore-not-found
    done

    # cert-manager
    log_info "  Removing cert-manager operator..."
    delete_if_exists subscription openshift-cert-manager-operator cert-manager-operator
    for csv in $(oc get csv -n cert-manager-operator --no-headers -o custom-columns='NAME:.metadata.name' 2>/dev/null | grep cert-manager || true); do
        run_cmd oc delete csv "$csv" -n cert-manager-operator --ignore-not-found
    done
    delete_namespace "cert-manager-operator"

    # Leader Worker Set
    log_info "  Removing Leader Worker Set operator..."
    delete_if_exists subscription leader-worker-set openshift-lws-operator
    for csv in $(oc get csv -n openshift-lws-operator --no-headers -o custom-columns='NAME:.metadata.name' 2>/dev/null | grep leader-worker-set || true); do
        run_cmd oc delete csv "$csv" -n openshift-lws-operator --ignore-not-found
    done
    delete_namespace "openshift-lws-operator"

    # RHOAI (last - it manages many resources)
    log_info "  Removing RHOAI operator..."
    delete_if_exists subscription rhods-operator redhat-ods-operator
    for csv in $(oc get csv -n redhat-ods-operator --no-headers -o custom-columns='NAME:.metadata.name' 2>/dev/null | grep rhods || true); do
        run_cmd oc delete csv "$csv" -n redhat-ods-operator --ignore-not-found
    done

    # Wait for RHOAI operator to clean up managed resources
    if [ "$DRY_RUN" = false ]; then
        log_info "  Waiting for RHOAI operator cleanup (60s)..."
        sleep 30
    fi

    delete_namespace "redhat-ods-operator"

    # Clean up RHOAI-managed namespaces
    delete_namespace "redhat-ods-applications"
    delete_namespace "redhat-ods-monitoring"
    delete_namespace "redhat-ai-gateway-infra"
    delete_namespace "rhods-notebooks"
    delete_namespace "rhoai-model-registries"
    # models-as-a-service may have Tenant CRs with finalizers stuck if operator is gone
    if oc get namespace models-as-a-service &>/dev/null 2>&1; then
        for tenant in $(oc get tenants.maas.opendatahub.io -n models-as-a-service --no-headers -o custom-columns='NAME:.metadata.name' 2>/dev/null || true); do
            log_info "  Removing finalizer from stuck tenant/$tenant..."
            run_cmd oc patch tenant "$tenant" -n models-as-a-service --type=merge -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true
        done
    fi
    delete_namespace "models-as-a-service"

    log_info "Operator cleanup complete"
elif should_run 7 && [ "$KEEP_OPERATORS" = true ]; then
    log_info "Skipping Phase 7 (--keep-operators)"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo -e "${BOLD}${GREEN}════════════════════════════════════════════${NC}"
echo -e "${BOLD}${GREEN}  Cleanup complete${NC}"
echo -e "${BOLD}${GREEN}════════════════════════════════════════════${NC}"

if [ "$DRY_RUN" = true ]; then
    log_warn "DRY RUN - no resources were actually deleted"
    log_info "Re-run without --dry-run to perform the cleanup"
fi

if [ "$KEEP_OPERATORS" = true ]; then
    log_info "Operators were kept (--keep-operators). To remove them, re-run with --from-phase 7"
fi

echo ""
log_info "To reinstall MaaS, run: ./scripts/setup-maas.sh"
