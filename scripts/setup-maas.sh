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
#   2. Platform Config - Configure Kuadrant, UWM, Gateway
#   3. MaaS Platform - Deploy PostgreSQL database
#   4. RHOAI Config  - Enable Models-as-a-Service
#
# Usage:
#   ./scripts/setup-2.sh [OPTIONS]
#
# Options:
#   --from-phase N    Start execution from phase N (default: 0)
#   --to-phase M      Run up to and including phase M (default: 4)
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
  --to-phase M      Run up to and including phase M (default: 4)
  -h, --help        Display this help message

Phases:
  0  Preflight       Detect and display cluster state
  1  Prerequisites   Install operators and MetalLB (if needed)
  2  Platform Config Configure Kuadrant, UWM, Gateway
  3  MaaS Platform   Deploy PostgreSQL database
  4  RHOAI Config    Enable Models-as-a-Service

Examples:
  # Run all phases (default)
  ./scripts/setup-2.sh

  # Run only preflight to check cluster state
  ./scripts/setup-2.sh --from-phase 0 --to-phase 0

  # Run only Phase 1
  ./scripts/setup-2.sh --from-phase 1 --to-phase 1

  # Run only Phase 2
  ./scripts/setup-2.sh --from-phase 2 --to-phase 2

  # Run only Phase 3
  ./scripts/setup-2.sh --from-phase 3 --to-phase 3

  # Run only Phase 4
  ./scripts/setup-2.sh --from-phase 4 --to-phase 4

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
TO_PHASE=4
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

if [ "$FROM_PHASE" -lt 0 ] || [ "$FROM_PHASE" -gt 4 ]; then
    log_error "Invalid --from-phase: $FROM_PHASE (must be 0-4)"
    exit 1
fi

if [ "$TO_PHASE" -lt 0 ] || [ "$TO_PHASE" -gt 4 ]; then
    log_error "Invalid --to-phase: $TO_PHASE (must be 0-4)"
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

# =============================================================================
# Phase 2: Platform Configuration
# =============================================================================
if should_run 2; then
    log_phase 2 "Platform Configuration"

    # Step 1: Kuadrant and Authorino
    log_step "Installing Kuadrant and Authorino..."

    log_info "Creating kuadrant-system namespace..."
    oc apply -f "$MANIFESTS_DIR/02-platform-config/kuadrant/namespace.yaml"

    log_info "Configuring Authorino service with TLS cert annotation..."
    oc apply -f "$MANIFESTS_DIR/02-platform-config/kuadrant/service-annotation.yaml"

    log_info "Creating Kuadrant CR..."
    oc apply -f "$MANIFESTS_DIR/02-platform-config/kuadrant/kuadrant.yaml"

    log_info "Waiting for Kuadrant to become ready..."
    if ! oc wait --for=condition=Ready kuadrant/kuadrant -n kuadrant-system --timeout=120s 2>/dev/null; then
        KUADRANT_MSG=$(oc get kuadrant kuadrant -n kuadrant-system \
            -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}' 2>/dev/null || echo "")
        if echo "$KUADRANT_MSG" | grep -i "MissingDependency" >/dev/null 2>&1; then
            log_warn "Kuadrant reports MissingDependency (Istio race) - restarting operator pod..."
            oc delete pod -n openshift-operators \
                $(oc get pods -n openshift-operators --no-headers | grep kuadrant-operator | awk '{print $1}')
            log_info "Waiting for Kuadrant to become ready (retry)..."
            oc wait --for=condition=Ready kuadrant/kuadrant -n kuadrant-system --timeout=180s
        else
            log_error "Kuadrant did not become Ready - check: oc get kuadrant kuadrant -n kuadrant-system -o yaml"
            exit 1
        fi
    fi
    log_info "Kuadrant: Ready"

    # Step 2: Configure TLS for Authorino
    log_step "Configuring TLS for Authorino..."

    log_info "Verifying authorino-server-cert Secret exists..."
    oc get secret authorino-server-cert -n kuadrant-system

    log_info "Patching Authorino CR to enable TLS listener..."
    oc patch authorino authorino -n kuadrant-system --type=merge --patch '{
  "spec": {
    "listener": {
      "tls": {
        "enabled": true,
        "certSecretRef": {
          "name": "authorino-server-cert"
        }
      }
    }
  }
}'

    log_info "Configuring Authorino deployment with TLS certificate env vars..."
    oc -n kuadrant-system set env deployment/authorino \
      SSL_CERT_FILE=/etc/ssl/certs/openshift-service-ca/service-ca-bundle.crt \
      REQUESTS_CA_BUNDLE=/etc/ssl/certs/openshift-service-ca/service-ca-bundle.crt

    log_info "Waiting for Authorino deployment to become available..."
    oc wait --for=condition=Available deployment/authorino -n kuadrant-system --timeout=300s
    log_info "Authorino deployment: Available"

    # Step 3: User Workload Monitoring
    log_step "Enabling User Workload Monitoring..."

    log_info "Applying User Workload Monitoring configuration..."
    oc apply -k "$MANIFESTS_DIR/02-platform-config/uwm/"

    log_info "Waiting for prometheus-operator deployment (may take 10-20s to appear)..."
    # Wait for deployment to exist first
    elapsed=0
    while [ $elapsed -lt 60 ]; do
        if oc get deployment prometheus-operator -n openshift-user-workload-monitoring &>/dev/null; then
            break
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done

    if [ $elapsed -ge 60 ]; then
        log_error "prometheus-operator deployment did not appear within 60s"
        exit 1
    fi

    log_info "Waiting for prometheus-operator to become available..."
    oc wait --for=condition=Available deployment/prometheus-operator \
      -n openshift-user-workload-monitoring --timeout=300s

    log_info "Waiting for Prometheus pods to be running..."
    # Wait for prometheus-user-workload-0
    if ! oc get pod prometheus-user-workload-0 -n openshift-user-workload-monitoring &>/dev/null; then
        log_info "  Waiting for prometheus-user-workload-0 pod to appear..."
        elapsed=0
        while [ $elapsed -lt 300 ]; do
            if oc get pod prometheus-user-workload-0 -n openshift-user-workload-monitoring &>/dev/null; then
                break
            fi
            sleep 5
            elapsed=$((elapsed + 5))
        done
    fi
    oc wait --for=condition=Ready pod/prometheus-user-workload-0 \
      -n openshift-user-workload-monitoring --timeout=300s

    # Wait for thanos-ruler-user-workload-0
    if ! oc get pod thanos-ruler-user-workload-0 -n openshift-user-workload-monitoring &>/dev/null; then
        log_info "  Waiting for thanos-ruler-user-workload-0 pod to appear..."
        elapsed=0
        while [ $elapsed -lt 300 ]; do
            if oc get pod thanos-ruler-user-workload-0 -n openshift-user-workload-monitoring &>/dev/null; then
                break
            fi
            sleep 5
            elapsed=$((elapsed + 5))
        done
    fi
    oc wait --for=condition=Ready pod/thanos-ruler-user-workload-0 \
      -n openshift-user-workload-monitoring --timeout=300s

    log_info "Verifying all Prometheus pods are running..."
    oc get pods -n openshift-user-workload-monitoring

    # Step 4: GatewayClass
    log_step "Creating GatewayClass..."

    log_info "Applying GatewayClass resource..."
    oc apply -f "$MANIFESTS_DIR/02-platform-config/gatewayclass.yaml"

    log_info "Waiting for GatewayClass to be accepted..."
    oc wait --for=condition=Accepted gatewayclass/openshift-default --timeout=120s

    log_info "Verifying GatewayClass..."
    oc get gatewayclass openshift-default

    # Step 5: MaaS Gateway
    log_step "Creating MaaS Gateway..."

    # Platform type already detected in Phase 0, reuse if available
    if [ -z "${PLATFORM_TYPE:-}" ]; then
        PLATFORM_TYPE=$(oc get infrastructure cluster -o jsonpath='{.status.platform}')
        IS_CLOUD_PLATFORM=false
        case "$PLATFORM_TYPE" in
            AWS|GCP|Azure) IS_CLOUD_PLATFORM=true ;;
        esac
    fi
    log_info "Platform type: $PLATFORM_TYPE"

    # Step 5a.1: Verify MetalLB (Non-Cloud Only)
    if [ "$IS_CLOUD_PLATFORM" = false ]; then
        log_info "Non-cloud platform detected - verifying MetalLB is installed..."
        if ! oc get deployment metallb-operator-controller-manager -n metallb-system &>/dev/null; then
            log_error "MetalLB is not installed!"
            log_error "On non-cloud platforms, MetalLB is required for the Gateway to receive an external IP"
            log_error "The Gateway will never reach Programmed=True without MetalLB"
            echo ""
            log_error "To install MetalLB, run Phase 1:"
            log_error "  ./scripts/setup-2.sh --from-phase 1 --to-phase 1"
            echo ""
            exit 1
        fi
        log_info "MetalLB is installed"
    fi

    # Step 5b: Create Gateway
    log_info "Extracting cluster domain and TLS certificate name..."

    # Cluster domain (may already be set in Phase 0)
    if [ -z "${CLUSTER_DOMAIN:-}" ]; then
        CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
    fi
    echo "$CLUSTER_DOMAIN"

    # TLS certificate name (may already be set in Phase 0)
    if [ -z "${CERT_NAME:-}" ]; then
        CERT_NAME=$(oc get ingresscontroller default -n openshift-ingress-operator \
            -o jsonpath='{.spec.defaultCertificate.name}' 2>/dev/null)
        CERT_NAME="${CERT_NAME:-router-certs-default}"
    fi
    echo "$CERT_NAME"

    log_info "Creating MaaS Gateway with cluster-specific values..."
    export CLUSTER_DOMAIN
    export CERT_NAME
    envsubst '${CLUSTER_DOMAIN} ${CERT_NAME}' < "$MANIFESTS_DIR/02-platform-config/gateway.yaml.tmpl" | oc apply -f -

    # Step 5c: Annotate Gateway
    log_info "Annotating Gateway for Authorino TLS bootstrap..."
    oc annotate gateway maas-default-gateway -n openshift-ingress \
      security.opendatahub.io/authorino-tls-bootstrap="true" --overwrite

    # Wait for Gateway
    log_info "Waiting for Gateway to be programmed..."
    oc wait --for=condition=Programmed gateway/maas-default-gateway \
      -n openshift-ingress --timeout=120s

    # Check for OOMKilled gateway pods
    GATEWAY_POD_STATUS=$(oc get pods -n openshift-ingress --no-headers 2>/dev/null | grep "maas-default-gateway" | awk '{print $3}' || echo "")
    if echo "$GATEWAY_POD_STATUS" | grep -i "OOMKilled\|CrashLoopBackOff" >/dev/null 2>&1; then
        log_warn "Gateway pod is OOMKilled or in CrashLoopBackOff"
        log_warn "This is a known issue (RHOAIENG-68589) - increasing memory limit..."
        log_info "Patching gateway deployment to use 2Gi memory..."
        oc patch deployment maas-default-gateway-openshift-default -n openshift-ingress \
          --type=json -p '[{"op":"replace","path":"/spec/template/spec/containers/0/resources/limits/memory","value":"2Gi"}]'
        log_warn "Note: This patch may be reverted by Istio controller - re-apply if pods restart"
    fi

    # Step 5d: Passthrough Route (Non-Cloud Only)
    if [ "$IS_CLOUD_PLATFORM" = false ]; then
        log_step "Creating passthrough Route for non-cloud platform..."
        log_info "This routes external traffic to the Gateway's LoadBalancer service"

        export CLUSTER_DOMAIN
        envsubst '${CLUSTER_DOMAIN}' < "$MANIFESTS_DIR/03-maas-platform/openshift-gateway-setup/route.yaml.tmpl" | oc apply -f -

        log_info "Verifying Route was created..."
        oc get route maas-default-gateway-https -n openshift-ingress
    fi

    # Step 6: Verification
    log_step "Verifying Phase 2 configuration..."

    log_info "Checking Kuadrant..."
    oc get kuadrant -n kuadrant-system

    log_info "Checking Authorino with TLS..."
    oc get deployment authorino -n kuadrant-system
    oc get secret authorino-server-cert -n kuadrant-system

    log_info "Checking User Workload Monitoring..."
    oc get pods -n openshift-user-workload-monitoring

    log_info "Checking GatewayClass..."
    oc get gatewayclass openshift-default

    log_info "Checking Gateway..."
    oc get gateway maas-default-gateway -n openshift-ingress

    if [ "$IS_CLOUD_PLATFORM" = false ]; then
        log_info "Checking passthrough Route..."
        oc get route maas-default-gateway-https -n openshift-ingress -o jsonpath='{.status.ingress[0].conditions[?(@.type=="Admitted")].status}'
        echo ""
    fi

    log_info "Testing TLS connection to Gateway..."
    curl -vsk "https://maas.${CLUSTER_DOMAIN}" 2>&1 | grep -E "SSL connection|Connected" || \
        log_warn "TLS connection test failed - this may be normal if MaaS API is not yet deployed"

    # Final Summary
    echo ""
    log_info "========================================="
    log_info "Phase 2 Completion Summary"
    log_info "========================================="
    log_info "Kuadrant:              Ready"
    log_info "Authorino TLS:         Configured"
    log_info "User Workload Mon:     Enabled"
    log_info "GatewayClass:          Accepted"
    log_info "Gateway:               Programmed"
    if [ "$IS_CLOUD_PLATFORM" = false ]; then
        log_info "Passthrough Route:    Created"
    fi
    log_info "Cluster domain:        $CLUSTER_DOMAIN"
    log_info "TLS certificate:       $CERT_NAME"
    log_info "========================================="
    echo ""
fi

# =============================================================================
# Phase 3: MaaS Platform Infrastructure
# =============================================================================
if should_run 3; then
    log_phase 3 "MaaS Platform Infrastructure"

    # Step 1: Create PostgreSQL Secrets
    log_step "Creating PostgreSQL secrets..."

    # Check if secrets already exist (idempotent)
    if oc get secret postgres-creds -n redhat-ods-applications &>/dev/null; then
        log_info "Secret postgres-creds already exists, skipping creation"
    else
        log_info "Generating random PostgreSQL password..."
        POSTGRES_PASSWORD=$(openssl rand -base64 16 | tr -d '=+/')

        log_info "Creating postgres-creds secret..."
        oc create secret generic postgres-creds \
          -n redhat-ods-applications \
          --from-literal=POSTGRES_USER=maas \
          --from-literal=POSTGRES_PASSWORD="${POSTGRES_PASSWORD}" \
          --from-literal=POSTGRES_DB=maas
    fi

    # maas-db-config depends on postgres-creds
    if oc get secret maas-db-config -n redhat-ods-applications &>/dev/null; then
        log_info "Secret maas-db-config already exists, skipping creation"
    else
        # Extract password from existing secret (in case postgres-creds was already created)
        if [ -z "${POSTGRES_PASSWORD:-}" ]; then
            log_info "Extracting password from existing postgres-creds secret..."
            POSTGRES_PASSWORD=$(oc get secret postgres-creds -n redhat-ods-applications \
                -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d)
        fi

        log_info "Creating maas-db-config secret..."
        oc create secret generic maas-db-config \
          -n redhat-ods-applications \
          --from-literal=DB_CONNECTION_URL="postgresql://maas:${POSTGRES_PASSWORD}@postgres:5432/maas?sslmode=disable"
    fi

    log_info "PostgreSQL secrets created"

    # Step 2: Deploy PostgreSQL
    log_step "Deploying PostgreSQL database..."

    log_info "Applying PostgreSQL manifests..."
    oc apply -k "$MANIFESTS_DIR/03-maas-platform/"

    log_info "Waiting for PostgreSQL deployment to become available..."
    oc wait --for=condition=Available deployment/postgres \
      -n redhat-ods-applications --timeout=120s

    log_info "Verifying PostgreSQL pod is running..."
    oc get pods -n redhat-ods-applications -l app=postgres

    # Step 3: Verification
    log_step "Verifying Phase 3 configuration..."

    log_info "Checking PostgreSQL deployment..."
    oc get deployment postgres -n redhat-ods-applications

    log_info "Checking PostgreSQL pod status..."
    oc get pods -n redhat-ods-applications -l app=postgres

    log_info "Verifying PostgreSQL secrets exist..."
    oc get secret postgres-creds -n redhat-ods-applications
    oc get secret maas-db-config -n redhat-ods-applications

    log_info "Verifying Gateway is still programmed..."
    oc wait --for=condition=Programmed gateway/maas-default-gateway \
      -n openshift-ingress --timeout=60s

    # Final Summary
    echo ""
    log_info "========================================="
    log_info "Phase 3 Completion Summary"
    log_info "========================================="
    log_info "PostgreSQL:            Running"
    log_info "PostgreSQL secrets:    Created"
    log_info "Gateway:               Programmed"
    log_info "========================================="
    echo ""
fi

# =============================================================================
# Phase 4: RHOAI Configuration
# =============================================================================
if should_run 4; then
    log_phase 4 "RHOAI Configuration"

    # Step 1: Apply DSCInitialization
    log_step "Applying DSCInitialization..."

    log_info "Creating Data Science Cluster Initialization..."
    oc apply -f "$MANIFESTS_DIR/04-rhoai-config/dscinitialization.yaml"

    log_info "Waiting for DSCI to be Ready (this may take a few minutes)..."
    oc wait --for=jsonpath='{.status.phase}'=Ready \
      dscinitialization/default-dsci --timeout=600s

    log_info "DSCI: Ready"

    # Step 2: Apply DataScienceCluster
    log_step "Applying DataScienceCluster..."

    log_info "Creating Data Science Cluster (enables MaaS and all components)..."
    oc apply -f "$MANIFESTS_DIR/04-rhoai-config/datasciencecluster.yaml"

    log_info "Waiting for DSC to be Ready (this may take several minutes)..."
    oc wait --for=jsonpath='{.status.phase}'=Ready \
      datasciencecluster/default-dsc --timeout=600s

    log_info "DataScienceCluster: Ready"

    # Step 3: Apply OdhDashboardConfig
    log_step "Applying OdhDashboardConfig..."

    log_info "Configuring RHOAI dashboard (enables MaaS UI features)..."
    oc apply -f "$MANIFESTS_DIR/04-rhoai-config/odh-dashboard-config.yaml"

    log_info "Dashboard configuration applied"

    # Step 4: Verification
    log_step "Verifying Phase 4 configuration..."

    log_info "Checking MaaS CRDs are installed..."
    oc get crd | grep maas.opendatahub.io

    log_info "Expected MaaS CRDs:"
    log_info "  - externalmodels.maas.opendatahub.io"
    log_info "  - maasauthpolicies.maas.opendatahub.io"
    log_info "  - maasmodelrefs.maas.opendatahub.io"
    log_info "  - maassubscriptions.maas.opendatahub.io"
    log_info "  - tenants.maas.opendatahub.io"

    log_info "Waiting for maas-api deployment (may take 30-60s to appear)..."
    # Wait for maas-api deployment to exist
    elapsed=0
    while [ $elapsed -lt 120 ]; do
        if oc get deployment maas-api -n redhat-ods-applications &>/dev/null; then
            break
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done

    if [ $elapsed -ge 120 ]; then
        log_error "maas-api deployment did not appear within 120s"
        exit 1
    fi

    log_info "Waiting for maas-api to be ready..."
    oc rollout status deployment/maas-api -n redhat-ods-applications --timeout=120s

    log_info "Checking default tenant..."
    oc get tenant default-tenant -n models-as-a-service

    log_info "Note: Tenant may show Ready=False (DeploymentsNotReady) - this is normal"
    log_info "      It will become Ready=True after deploying a model in Phase 5"

    log_info "Testing MaaS health endpoint..."
    # Cluster domain already set in Phase 0 or Phase 2
    if [ -z "${CLUSTER_DOMAIN:-}" ]; then
        CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
    fi

    HEALTH_RESPONSE=$(curl -sk "https://maas.${CLUSTER_DOMAIN}/maas-api/health" 2>/dev/null || echo "")
    if echo "$HEALTH_RESPONSE" | grep -q "healthy"; then
        log_info "MaaS API health check: OK"
    else
        log_warn "MaaS API health check failed - may not be ready yet"
        log_warn "Response: $HEALTH_RESPONSE"
    fi

    log_info "Checking dashboard configuration flags..."
    oc get odhdashboardconfig odh-dashboard-config -n redhat-ods-applications \
      -o jsonpath='{.spec.dashboardConfig}' | jq . || \
      log_warn "jq not available - skipping dashboard config display"

    # Final Summary
    echo ""
    log_info "========================================="
    log_info "Phase 4 Completion Summary"
    log_info "========================================="
    log_info "DSCInitialization:     Ready"
    log_info "DataScienceCluster:    Ready"
    log_info "Dashboard Config:      Applied"
    log_info "MaaS API:              Running"
    log_info "MaaS CRDs:             Installed"
    log_info "Default Tenant:        Created"
    log_info "========================================="
    echo ""
fi

log_info "Script execution complete"
