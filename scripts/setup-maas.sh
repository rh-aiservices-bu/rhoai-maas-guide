#!/usr/bin/env bash
#
# setup-2.sh - RHOAI MaaS Installation Script
#
# Automates the installation of Red Hat OpenShift AI Models as a Service (MaaS)
# following the official guide at https://github.com/rh-aiservices-bu/rhoai-maas-guide
#
# This script executes commands exactly as documented in the guide's .adoc files.
#
# Phases:
#   0. Preflight     - Detect and display cluster state
#   1. Prerequisites - Install operators and MetalLB (if needed)
#
# Usage:
#   ./scripts/setup-2.sh [OPTIONS]
#
# Options:
#   --from-phase N    Start execution from phase N (default: 0)
#   --to-phase M      Run up to and including phase M (default: 1)
#   -h, --help        Display help message
#
# Examples:
#   ./scripts/setup-2.sh
#   ./scripts/setup-2.sh --from-phase 0 --to-phase 0
#   ./scripts/setup-2.sh --from-phase 1 --to-phase 1
#   export METALLB_IP_RANGE='192.168.1.240-192.168.1.250' && ./scripts/setup-2.sh
#

set -euo pipefail

# =============================================================================
# Directory Setup
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUIDE_DIR="$SCRIPT_DIR/.."
MANIFESTS_DIR="$GUIDE_DIR/manifests"

# =============================================================================
# Logging Functions
# =============================================================================
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
log_phase() {
    echo -e "\n${BOLD}${BLUE}════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${BLUE}  Phase $1: $2${NC}"
    echo -e "${BOLD}${BLUE}════════════════════════════════════════════${NC}"
}

# =============================================================================
# Help Documentation
# =============================================================================
show_help() {
    cat << EOF
Usage: setup-2.sh [OPTIONS]

Automate RHOAI MaaS installation following the official guide.

Options:
  --from-phase N    Start execution from phase N (default: 0)
  --to-phase M      Run up to and including phase M (default: 1)
  -h, --help        Display this help message

Phases:
  0  Preflight      Detect and display cluster state
  1  Prerequisites  Install operators and MetalLB (if needed)

Examples:
  # Run preflight and Phase 1 (default)
  ./scripts/setup-2.sh

  # Run only preflight to check cluster state
  ./scripts/setup-2.sh --from-phase 0 --to-phase 0

  # Run only Phase 1 (skip preflight)
  ./scripts/setup-2.sh --from-phase 1 --to-phase 1

  # Run Phase 1 with custom MetalLB IP range (non-cloud platforms)
  export METALLB_IP_RANGE='192.168.1.240-192.168.1.250'
  ./scripts/setup-2.sh --from-phase 1 --to-phase 1

Environment Variables:
  METALLB_IP_RANGE  IP range for MetalLB pool (format: <start-ip>-<end-ip>)
                    Required for multi-node non-cloud clusters
                    Auto-detected for SNO clusters

Note: All commands run from repository root. Ensure 'oc' CLI is logged in.
EOF
}

# =============================================================================
# Argument Parsing
# =============================================================================
FROM_PHASE=0
TO_PHASE=1
SHOW_HELP=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --from-phase)
            FROM_PHASE="$2"
            shift 2
            ;;
        --to-phase)
            TO_PHASE="$2"
            shift 2
            ;;
        -h|--help)
            SHOW_HELP=true
            shift
            ;;
        *)
            log_error "Unknown option: $1"
            echo "Run with --help for usage information"
            exit 1
            ;;
    esac
done

if [ "$SHOW_HELP" = true ]; then
    show_help
    exit 0
fi

# =============================================================================
# Validation
# =============================================================================
if ! [[ "$FROM_PHASE" =~ ^[0-9]+$ ]] || ! [[ "$TO_PHASE" =~ ^[0-9]+$ ]]; then
    log_error "Phase numbers must be integers"
    exit 1
fi

if [ "$FROM_PHASE" -lt 0 ] || [ "$FROM_PHASE" -gt 1 ]; then
    log_error "Invalid --from-phase: $FROM_PHASE (must be 0-1)"
    exit 1
fi

if [ "$TO_PHASE" -lt 0 ] || [ "$TO_PHASE" -gt 1 ]; then
    log_error "Invalid --to-phase: $TO_PHASE (must be 0-1)"
    exit 1
fi

if [ "$FROM_PHASE" -gt "$TO_PHASE" ]; then
    log_error "--from-phase ($FROM_PHASE) cannot be greater than --to-phase ($TO_PHASE)"
    exit 1
fi

# =============================================================================
# Helper Functions
# =============================================================================
should_run() {
    local phase=$1
    [ "$phase" -ge "$FROM_PHASE" ] && [ "$phase" -le "$TO_PHASE" ]
}

wait_for_csv() {
    local namespace=$1
    local label=$2
    local description=$3
    local timeout=${4:-600}

    log_info "Waiting for $description CSV to appear and reach Succeeded status..."

    # First, wait for CSV to appear (may take 30-60s after subscription creation)
    local elapsed=0
    while [ $elapsed -lt $timeout ]; do
        if oc get csv -n "$namespace" -l "$label=" --no-headers 2>/dev/null | grep -q .; then
            break
        fi
        sleep 5
        elapsed=$((elapsed + 5))
        if [ $((elapsed % 30)) -eq 0 ]; then
            log_info "  Still waiting for CSV to appear... (${elapsed}s elapsed)"
        fi
    done

    if [ $elapsed -ge $timeout ]; then
        log_error "$description CSV did not appear within ${timeout}s"
        return 1
    fi

    log_info "  CSV found, waiting for Succeeded status..."

    # Now wait for it to reach Succeeded
    local remaining=$((timeout - elapsed))
    if ! oc wait csv -n "$namespace" -l "$label=" \
        --for=jsonpath='{.status.phase}'=Succeeded --timeout="${remaining}s" 2>/dev/null; then
        log_error "$description CSV did not reach Succeeded within timeout"
        return 1
    fi

    log_info "  $description CSV: Succeeded"
    return 0
}

# =============================================================================
# Phase 0: Preflight
# =============================================================================
if should_run 0; then
    log_phase 0 "Preflight"

    # Verify logged into cluster
    if ! oc whoami &>/dev/null; then
        log_error "Not logged into OpenShift cluster. Run: oc login <cluster>"
        exit 1
    fi
    log_info "Cluster: $(oc whoami --show-server)"
    log_info "User:    $(oc whoami)"

    # Detect cluster domain
    CLUSTER_DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}' 2>/dev/null || echo "")
    if [ -z "$CLUSTER_DOMAIN" ]; then
        log_error "Cannot detect cluster domain. Is this an OpenShift cluster?"
        exit 1
    fi
    log_info "Cluster domain: ${CLUSTER_DOMAIN}"

    # Detect TLS certificate name
    CERT_NAME=$(oc get ingresscontroller default -n openshift-ingress-operator \
        -o jsonpath='{.spec.defaultCertificate.name}' 2>/dev/null || echo "")
    [ -z "$CERT_NAME" ] && CERT_NAME="router-certs-default"
    log_info "TLS certificate: ${CERT_NAME}"

    # Detect cloud vs non-cloud platform
    PLATFORM_TYPE=$(oc get infrastructure cluster -o jsonpath='{.status.platform}' 2>/dev/null || echo "Unknown")
    IS_CLOUD_PLATFORM=false
    case "$PLATFORM_TYPE" in
        AWS|GCP|Azure) IS_CLOUD_PLATFORM=true ;;
    esac
    log_info "Platform type: ${PLATFORM_TYPE} (cloud LB: ${IS_CLOUD_PLATFORM})"

    # Detect Single Node OpenShift (SNO)
    NODE_COUNT=$(oc get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
    IS_SNO=false
    if [ "$NODE_COUNT" -eq 1 ]; then
        IS_SNO=true
        log_info "Cluster topology: Single Node OpenShift (SNO)"
        if [ "$IS_CLOUD_PLATFORM" = false ]; then
            log_warn "SNO bare-metal detected: MetalLB will use node's internal IP for LoadBalancer"
        fi
    elif [ "$NODE_COUNT" -gt 1 ]; then
        log_info "Cluster topology: Multi-node (${NODE_COUNT} nodes)"
    else
        log_warn "Cluster topology: Unknown (could not detect node count)"
    fi

    # Detect existing components
    HAS_RHOAI_CSV=false
    HAS_RHCL_CSV=false
    HAS_METALLB=false

    RHOAI_CSVS=$(oc get csv -n redhat-ods-operator --no-headers 2>/dev/null || true)
    echo "$RHOAI_CSVS" | grep rhods >/dev/null 2>&1 && HAS_RHOAI_CSV=true
    RHCL_CSVS=$(oc get csv -n openshift-operators --no-headers 2>/dev/null || true)
    echo "$RHCL_CSVS" | grep rhcl >/dev/null 2>&1 && HAS_RHCL_CSV=true
    METALLB_CSVS=$(oc get csv -n metallb-system --no-headers 2>/dev/null || true)
    echo "$METALLB_CSVS" | grep "metallb-operator" >/dev/null 2>&1 && HAS_METALLB=true

    echo ""
    log_info "Detected state:"
    log_info "  Platform type:      ${PLATFORM_TYPE}"
    log_info "  Node count:         ${NODE_COUNT}"
    log_info "  Is SNO:             $([ "$IS_SNO" = true ] && echo "yes" || echo "no")"
    log_info "  RHOAI operator:     $([ "$HAS_RHOAI_CSV" = true ] && echo "installed" || echo "not found")"
    log_info "  RHCL operator:      $([ "$HAS_RHCL_CSV" = true ] && echo "installed" || echo "not found")"
    log_info "  MetalLB operator:   $([ "$HAS_METALLB" = true ] && echo "installed" || echo "not found")"
    echo ""
fi

# =============================================================================
# Phase 1: Prerequisites
# =============================================================================
if should_run 1; then
    log_phase 1 "Prerequisites"

    # Step 1: Install Required Operators
    log_step "Installing required operator subscriptions..."
    oc apply -k "$MANIFESTS_DIR/01-prerequisites/operators/"
    log_info "Operator subscriptions applied"

    # Step 2: Wait for Operator CSVs
    log_step "Waiting for operator CSVs to install (this may take 2-5 minutes)..."

    wait_for_csv "redhat-ods-operator" "operators.coreos.com/rhods-operator.redhat-ods-operator" "RHOAI operator" 600
    wait_for_csv "openshift-operators" "operators.coreos.com/rhcl-operator.openshift-operators" "Red Hat Connectivity Link operator" 600
    wait_for_csv "cert-manager-operator" "operators.coreos.com/openshift-cert-manager-operator.cert-manager-operator" "cert-manager operator" 600
    wait_for_csv "openshift-operators" "operators.coreos.com/servicemeshoperator3.openshift-operators" "Service Mesh 3 operator" 600
    wait_for_csv "openshift-lws-operator" "operators.coreos.com/leader-worker-set.openshift-lws-operator" "Leader Worker Set operator" 600

    log_info "All required operator CSVs ready"

    # Step 3: MetalLB Detection and Installation
    log_step "Detecting platform type..."
    PLATFORM_TYPE=$(oc get infrastructure cluster -o jsonpath='{.status.platform}')
    log_info "Platform type: $PLATFORM_TYPE"

    IS_CLOUD_PLATFORM=false
    case "$PLATFORM_TYPE" in
        AWS|GCP|Azure)
            IS_CLOUD_PLATFORM=true
            log_info "Cloud platform detected - MetalLB not needed"
            ;;
    esac

    if [ "$IS_CLOUD_PLATFORM" = false ]; then
        log_step "Non-cloud platform detected - installing MetalLB..."

        log_info "Installing MetalLB operator..."
        oc apply -k "$MANIFESTS_DIR/01-prerequisites/metallb/"

        wait_for_csv "metallb-system" "operators.coreos.com/metallb-operator.metallb-system" "MetalLB operator" 120

        log_info "Creating MetalLB CR..."
        oc apply -f "$MANIFESTS_DIR/01-prerequisites/metallb/metallb.yaml"

        log_step "Configuring MetalLB IP pool..."
        NODE_COUNT=$(oc get nodes --no-headers 2>/dev/null | wc -l)
        IS_SNO=false
        [ "$NODE_COUNT" -eq 1 ] && IS_SNO=true

        if [ "$IS_SNO" = true ]; then
            log_info "Single-node OpenShift detected - using node internal IP"
            METALLB_IP_RANGE="$(oc get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')-$(oc get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')"
            echo "$METALLB_IP_RANGE"
            log_info "MetalLB IP range (SNO): $METALLB_IP_RANGE"
        else
            NODE_IP=$(oc get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "")
            if [ -z "${METALLB_IP_RANGE:-}" ]; then
                log_warn "Multi-node cluster detected"
                log_warn "Please set METALLB_IP_RANGE environment variable to an unused IP range"
                log_warn "Example: export METALLB_IP_RANGE='192.168.1.240-192.168.1.250'"
                log_warn "Using first node IP (${NODE_IP}) as fallback - this may not work for your network"
                METALLB_IP_RANGE="${NODE_IP}-${NODE_IP}"
            fi
            echo "$METALLB_IP_RANGE"
            log_info "MetalLB IP range: $METALLB_IP_RANGE"
        fi

        export METALLB_IP_RANGE
        envsubst < "$MANIFESTS_DIR/03-maas-platform/openshift-gateway-setup/metallb-config.yaml" | oc apply -f -
        log_info "MetalLB IP pool configured"
    fi

    # Step 4: Verification
    log_step "Verifying CRDs are available..."

    log_info "Checking for RHOAI CRD (datascienceclusters)..."
    if ! oc get crd datascienceclusters.datasciencecluster.opendatahub.io &>/dev/null; then
        log_warn "RHOAI CRD not yet available, waiting up to 60 seconds..."
        for i in {1..12}; do
            sleep 5
            if oc get crd datascienceclusters.datasciencecluster.opendatahub.io &>/dev/null; then
                log_info "RHOAI CRD is now available"
                break
            fi
        done
    fi
    oc get crd datascienceclusters.datasciencecluster.opendatahub.io

    log_info "Checking for Connectivity Link / Kuadrant CRD..."
    if ! oc get crd kuadrants.kuadrant.io &>/dev/null; then
        log_warn "Kuadrant CRD not yet available, waiting up to 60 seconds..."
        for i in {1..12}; do
            sleep 5
            if oc get crd kuadrants.kuadrant.io &>/dev/null; then
                log_info "Kuadrant CRD is now available"
                break
            fi
        done
    fi
    oc get crd kuadrants.kuadrant.io

    log_info "Checking for cert-manager CRD..."
    if ! oc get crd certificates.cert-manager.io &>/dev/null; then
        log_warn "cert-manager CRD not yet available, waiting up to 60 seconds..."
        for i in {1..12}; do
            sleep 5
            if oc get crd certificates.cert-manager.io &>/dev/null; then
                log_info "cert-manager CRD is now available"
                break
            fi
        done
    fi
    oc get crd certificates.cert-manager.io

    log_info "Checking for Service Mesh 3 CRD..."
    if ! oc get crd istios.sailoperator.io &>/dev/null; then
        log_warn "Service Mesh CRD not yet available, waiting up to 60 seconds..."
        for i in {1..12}; do
            sleep 5
            if oc get crd istios.sailoperator.io &>/dev/null; then
                log_info "Service Mesh CRD is now available"
                break
            fi
        done
    fi
    oc get crd istios.sailoperator.io

    log_info "Checking for Leader Worker Set CRD..."
    if ! oc get crd leaderworkersetoperators.operator.openshift.io &>/dev/null; then
        log_warn "Leader Worker Set CRD not yet available, waiting up to 60 seconds..."
        for i in {1..12}; do
            sleep 5
            if oc get crd leaderworkersetoperators.operator.openshift.io &>/dev/null; then
                log_info "Leader Worker Set CRD is now available"
                break
            fi
        done
    fi
    oc get crd leaderworkersetoperators.operator.openshift.io

    log_info "All required CRDs are available"

    log_step "Checking operator subscription status..."
    echo ""
    oc get subscriptions.operators.coreos.com -A \
      -o custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name,CSV:.status.currentCSV,STATE:.status.state'
    echo ""

    log_info "Expected subscriptions:"
    log_info "  - cert-manager-operator/openshift-cert-manager-operator (AtLatestKnown)"
    if [ "$IS_CLOUD_PLATFORM" = false ]; then
        log_info "  - metallb-system/metallb-operator (AtLatestKnown)"
    fi
    log_info "  - openshift-lws-operator/leader-worker-set (AtLatestKnown)"
    log_info "  - openshift-operators/authorino-operator-* (AtLatestKnown)"
    log_info "  - openshift-operators/dns-operator-* (AtLatestKnown)"
    log_info "  - openshift-operators/limitador-operator-* (AtLatestKnown)"
    log_info "  - openshift-operators/rhcl-operator (AtLatestKnown)"
    log_info "  - openshift-operators/servicemeshoperator3 (AtLatestKnown)"
    log_info "  - redhat-ods-operator/rhods-operator (AtLatestKnown)"

    # Final Summary
    echo ""
    log_info "========================================="
    log_info "Phase 1 Completion Summary"
    log_info "========================================="
    log_info "Required operators:    Installed"
    log_info "Platform type:         $PLATFORM_TYPE"
    if [ "$IS_CLOUD_PLATFORM" = false ]; then
        log_info "MetalLB:              Installed"
        log_info "MetalLB IP Range:     $METALLB_IP_RANGE"
    fi
    log_info "========================================="
    echo ""
fi

log_info "Script execution complete"
