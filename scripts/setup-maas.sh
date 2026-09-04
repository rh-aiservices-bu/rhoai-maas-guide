#!/usr/bin/env bash
#
# setup-maas.sh - End-to-end MaaS (Models as a Service) deployment on RHOAI
#
# Orchestrates the full MaaS lifecycle from a bare OpenShift cluster:
#   Phase 0: Preflight  - detect cluster state, decide which phases to run
#   Phase 1: Operators  - install required operator subscriptions
#   Phase 2: Platform config  - Kuadrant, UWM, GatewayClass, Gateway
#   Phase 3: MaaS platform  - PostgreSQL secrets/deployment, Authorino TLS
#   Phase 4: RHOAI config   - DataScienceCluster, DSCInitialization, Dashboard
#   Phase 5: Deploy model  - auto-detect GPU, apply model Kustomize
#   Phase 6: Verify  - run 6-phase E2E verification
#   Phase 7: Observability (optional)  - Tempo + OpenTelemetry + COO + Gateway telemetry
#   Phase 8: External models (optional) - deploy ExternalModel (e.g. OpenAI, Gemini)
#
# Each phase is idempotent  - re-running skips what's already done.
#
# Usage:
#   ./scripts/setup-maas.sh [OPTIONS]
#
# Options:
#   --model <name>       Model: simulator, granite-tiny-gpu, gpt-oss-20b, auto (default: auto)
#   --from-phase <N>     Start from phase N (default: 0)
#   --skip-models        Skip Phase 5 (model deployment)
#   --skip-verify        Skip Phase 6 (verification)
#   --with-observability Also run Phase 7 (Tempo + OpenTelemetry + COO + telemetry + Loki usage dashboards)
#   --with-external-models Also run Phase 8 (ExternalModel deployment)
#   --maas-hostname <h>  Custom gateway hostname (default: maas.<cluster-domain>, or MAAS_HOSTNAME env var)
#   --external-model-api-key <key>  API key for external provider (or EXTERNAL_MODEL_API_KEY env var)
#   --dry-run            Preview without applying
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
log_phase() { echo -e "\n${BOLD}${BLUE}════════════════════════════════════════════${NC}"; echo -e "${BOLD}${BLUE}  Phase $1: $2${NC}"; echo -e "${BOLD}${BLUE}════════════════════════════════════════════${NC}"; }

MODEL="auto"
FROM_PHASE=0
SKIP_MODELS=false
SKIP_VERIFY=false
WITH_OBSERVABILITY=false
WITH_EXTERNAL_MODELS=false
MAAS_HOSTNAME="${MAAS_HOSTNAME:-}"
EXTERNAL_MODEL_PROVIDER="${EXTERNAL_MODEL_PROVIDER:-openai}"
EXTERNAL_MODEL_API_KEY="${EXTERNAL_MODEL_API_KEY:-}"
RHOAI_TARGET_VERSION=""
DISCONNECTED=${DISCONNECTED:-false}
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --model) MODEL="$2"; shift 2 ;;
        --from-phase) FROM_PHASE="$2"; shift 2 ;;
        --skip-models) SKIP_MODELS=true; shift ;;
        --skip-verify) SKIP_VERIFY=true; shift ;;
        --with-observability) WITH_OBSERVABILITY=true; shift ;;
        --with-external-models) WITH_EXTERNAL_MODELS=true; shift ;;
        --maas-hostname) MAAS_HOSTNAME="$2"; shift 2 ;;
        --external-model-provider) EXTERNAL_MODEL_PROVIDER="$2"; shift 2 ;;
        --external-model-api-key) EXTERNAL_MODEL_API_KEY="$2"; shift 2 ;;
        --rhoai-version) RHOAI_TARGET_VERSION="$2"; shift 2 ;;
        --disconnected) DISCONNECTED=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        -h|--help)
            cat <<'EOF'
Usage: setup-maas.sh [OPTIONS]

End-to-end MaaS deployment on RHOAI 3.4/3.5. Runs all phases from operator
installation through model deployment and verification. Each phase is
idempotent  - re-running skips what's already done.

Options:
  --model <name>       Model: simulator, granite-tiny-gpu, gpt-oss-20b, gemma, auto (default: auto)
  --rhoai-version <v>  RHOAI version: 3.4 or 3.5 (default: 3.5). Auto-detects if already installed.
  --from-phase <N>     Start from phase N (0-8, default: 0)
  --maas-hostname <h>  Custom gateway hostname (default: maas.<cluster-domain>, or MAAS_HOSTNAME env var)
  --skip-models        Skip Phase 5 (model deployment)
  --skip-verify        Skip Phase 6 (verification)
  --disconnected       Disconnected/air-gapped mode (oci:// URIs, skip Phase 8)
  --with-observability Also run Phase 7 (Tempo + OpenTelemetry + COO + telemetry + Loki usage dashboards)
  --with-external-models Also run Phase 8 (ExternalModel deployment + test)
  --external-model-provider <p>   Provider: openai (default), gemini, bedrock (or set EXTERNAL_MODEL_PROVIDER)
  --external-model-api-key <key>  API key for external provider (or set EXTERNAL_MODEL_API_KEY)
  --dry-run            Preview without applying
  -h, --help           Show this help message

Phases:
  0  Preflight          Detect cluster state, decide which phases to run
  1  Operators          Install required operator subscriptions (RHOAI, RHCL, etc.)
  2  Platform config    Kuadrant, UWM, GatewayClass, Gateway
  3  MaaS platform      PostgreSQL secrets/deployment, Authorino TLS
  4  RHOAI config       DSC with MaaS: Managed, Dashboard flags
  5  Deploy model       Auto-detect GPU, apply model Kustomize manifests
  6  Verify             6-phase E2E verification (API, auth, rate limits)
  7  Observability      Tempo + OpenTelemetry + COO + telemetry + Loki usage dashboards (only with --with-observability)
  8  External models    ExternalModel + governance (only with --with-external-models, skipped in --disconnected)

Auto-detection (--model auto):
  No GPU             -> simulator (CPU-only, ~30s startup)
  GPU VRAM >= 40 GiB -> gpt-oss-20b (L40S, A100, H100)
  GPU VRAM >= 16 GiB -> gemma (L4, L40)
  GPU VRAM <  16 GiB -> granite-tiny-gpu (L4)
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

wait_for() {
    local desc="$1"; shift
    local timeout="${1:-120}"; shift
    log_info "Waiting for $desc (timeout: ${timeout}s)..."
    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY RUN] Would wait for: $desc"
        return 0
    fi
    if ! "$@" --timeout="${timeout}s" 2>/dev/null; then
        log_warn "$desc did not complete within ${timeout}s"
        return 1
    fi
    log_info "$desc: done"
}

wait_for_crd() {
    local crd_name="$1"
    local timeout="${2:-300}"
    local elapsed=0
    log_info "Waiting for CRD ${crd_name}..."
    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY RUN] Would wait for CRD: $crd_name"
        return 0
    fi
    while [ $elapsed -lt $timeout ]; do
        if oc get crd "$crd_name" &>/dev/null; then
            log_info "CRD ${crd_name}: registered"
            return 0
        fi
        sleep 10
        elapsed=$((elapsed + 10))
        [ $((elapsed % 60)) -eq 0 ] && log_info "  Still waiting for CRD ${crd_name}... (${elapsed}s)"
    done
    log_error "CRD ${crd_name} not registered within ${timeout}s"
    return 1
}

# =============================================================================
# Phase 0: Preflight
# =============================================================================
log_phase 0 "Preflight"

if ! oc whoami &>/dev/null; then
    log_error "Not logged into OpenShift cluster. Run: oc login <cluster>"
    exit 1
fi
log_info "Cluster: $(oc whoami --show-server)"
log_info "User:    $(oc whoami)"

# Detect cluster domain (needed by multiple phases)
CLUSTER_DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}' 2>/dev/null || echo "")
if [ -z "$CLUSTER_DOMAIN" ]; then
    log_error "Cannot detect cluster domain. Is this an OpenShift cluster?"
    exit 1
fi
log_info "Cluster domain: ${CLUSTER_DOMAIN}"
MAAS_HOSTNAME="${MAAS_HOSTNAME:-maas.${CLUSTER_DOMAIN}}"
log_info "MaaS hostname:  ${MAAS_HOSTNAME}"

# Detect TLS certificate name
CERT_NAME=$(oc get ingresscontroller default -n openshift-ingress-operator \
    -o jsonpath='{.spec.defaultCertificate.name}' 2>/dev/null || echo "")
[ -z "$CERT_NAME" ] && CERT_NAME="router-certs-default"
log_info "TLS certificate: ${CERT_NAME}"

# State detection
HAS_RHOAI_CSV=false
HAS_RHCL_CSV=false
HAS_KUADRANT=false
HAS_UWM=false
HAS_GATEWAY_CLASS=false
HAS_GATEWAY=false
HAS_DSC=false
HAS_MAAS_MANAGED=false
HAS_POSTGRES=false
HAS_MAAS_API=false
HAS_TENANT=false
HAS_MODELS=false
HAS_METALLB=false

# Detect cloud vs non-cloud platform (affects Gateway LB provisioning)
PLATFORM_TYPE=$(oc get infrastructure cluster -o jsonpath='{.status.platformStatus.type}' 2>/dev/null || echo "Unknown")
IS_CLOUD_PLATFORM=false
case "$PLATFORM_TYPE" in
    AWS|GCP|Azure) IS_CLOUD_PLATFORM=true ;;
esac
log_info "Platform type: ${PLATFORM_TYPE} (cloud LB: ${IS_CLOUD_PLATFORM})"

# Note: avoid grep -q in pipelines  - with pipefail, grep -q causes SIGPIPE (exit 141)
RHOAI_CSVS=$(oc get csv -n redhat-ods-operator --no-headers 2>/dev/null || true)
echo "$RHOAI_CSVS" | grep rhods >/dev/null 2>&1 && HAS_RHOAI_CSV=true

# Detect installed RHOAI version and resolve effective version
RHOAI_INSTALLED_VERSION=""
if [ "$HAS_RHOAI_CSV" = true ]; then
    RHOAI_INSTALLED_VERSION=$(echo "$RHOAI_CSVS" | grep rhods | awk '{print $1}' | grep -oE '[0-9]+\.[0-9]+' | head -1)
fi
if [ -n "$RHOAI_INSTALLED_VERSION" ]; then
    RHOAI_MAJOR_MINOR="$RHOAI_INSTALLED_VERSION"
    if [ -n "$RHOAI_TARGET_VERSION" ] && [ "$RHOAI_TARGET_VERSION" != "$RHOAI_MAJOR_MINOR" ]; then
        log_warn "RHOAI $RHOAI_MAJOR_MINOR already installed, ignoring --rhoai-version $RHOAI_TARGET_VERSION"
    fi
elif [ -n "$RHOAI_TARGET_VERSION" ]; then
    RHOAI_MAJOR_MINOR="$RHOAI_TARGET_VERSION"
else
    RHOAI_MAJOR_MINOR="3.5"
fi

# Derive namespace layout based on RHOAI version
GATEWAY_INFRA_NS=redhat-ai-gateway-infra
IS_35_PLUS=false
if printf '%s\n' "3.5" "$RHOAI_MAJOR_MINOR" | sort -V | head -1 | grep -qx "3.5"; then
    IS_35_PLUS=true
fi
if [ "$IS_35_PLUS" = true ]; then
    MAAS_API_NS="$GATEWAY_INFRA_NS"
else
    MAAS_API_NS="$NAMESPACE"
fi
RHCL_CSVS=$(oc get csv -n openshift-operators --no-headers 2>/dev/null || true)
echo "$RHCL_CSVS" | grep rhcl >/dev/null 2>&1 && HAS_RHCL_CSV=true
oc get kuadrant kuadrant -n kuadrant-system &>/dev/null && HAS_KUADRANT=true
UWM_CFG=$(oc get configmap cluster-monitoring-config -n openshift-monitoring -o jsonpath='{.data.config\.yaml}' 2>/dev/null || true)
echo "$UWM_CFG" | grep enableUserWorkload >/dev/null 2>&1 && HAS_UWM=true
oc get gatewayclass openshift-default &>/dev/null && HAS_GATEWAY_CLASS=true
oc get gateway maas-default-gateway -n openshift-ingress &>/dev/null && HAS_GATEWAY=true
oc get datasciencecluster default-dsc &>/dev/null && HAS_DSC=true
if [ "$HAS_DSC" = true ]; then
    MAAS_STATE=$(oc get datasciencecluster default-dsc -o jsonpath='{.spec.components.kserve.modelsAsService.managementState}' 2>/dev/null || echo "")
    MAAS_STATE_35=$(oc get datasciencecluster default-dsc -o jsonpath='{.spec.components.aigateway.modelsAsAService.managementState}' 2>/dev/null || echo "")
    [ "$MAAS_STATE" = "Managed" ] || [ "$MAAS_STATE_35" = "Managed" ] && HAS_MAAS_MANAGED=true
fi
oc get deployment postgres -n "$NAMESPACE" &>/dev/null && HAS_POSTGRES=true
oc get deployment maas-api -n "$MAAS_API_NS" &>/dev/null && HAS_MAAS_API=true
if [ "$HAS_MAAS_API" = false ]; then
    oc get deployment maas-api -n "$NAMESPACE" &>/dev/null && HAS_MAAS_API=true && MAAS_API_NS="$NAMESPACE"
fi
# 3.5+ uses Config CR, 3.4 uses Tenant CR
TENANT_COUNT=$(oc get tenant -n models-as-a-service --no-headers 2>/dev/null | wc -l | tr -d ' ' || echo "0")
CONFIG_COUNT=$(oc get configs.maas.opendatahub.io --no-headers 2>/dev/null | wc -l | tr -d ' ' || echo "0")
{ [ "$TENANT_COUNT" -gt 0 ] || [ "$CONFIG_COUNT" -gt 0 ]; } 2>/dev/null && HAS_TENANT=true
MODEL_COUNT=$(oc get llminferenceservice -n llm --no-headers 2>/dev/null | wc -l | tr -d ' ' || echo "0")
[ "$MODEL_COUNT" -gt 0 ] 2>/dev/null && HAS_MODELS=true
METALLB_CSVS=$(oc get csv -n metallb-system --no-headers 2>/dev/null || true)
echo "$METALLB_CSVS" | grep "metallb-operator" >/dev/null 2>&1 && HAS_METALLB=true

echo ""
log_info "Detected state:"
log_info "  RHOAI version:      ${RHOAI_MAJOR_MINOR} (3.5+: ${IS_35_PLUS})"
log_info "  maas-api namespace: ${MAAS_API_NS}"
log_info "  RHOAI operator:     $([ "$HAS_RHOAI_CSV" = true ] && echo "installed" || echo "not found")"
log_info "  RHCL operator:      $([ "$HAS_RHCL_CSV" = true ] && echo "installed" || echo "not found")"
log_info "  Kuadrant CR:        $([ "$HAS_KUADRANT" = true ] && echo "ready" || echo "not found")"
log_info "  User Workload Mon:  $([ "$HAS_UWM" = true ] && echo "enabled" || echo "not enabled")"
log_info "  GatewayClass:       $([ "$HAS_GATEWAY_CLASS" = true ] && echo "exists" || echo "not found")"
log_info "  Gateway:            $([ "$HAS_GATEWAY" = true ] && echo "exists" || echo "not found")"
log_info "  DataScienceCluster: $([ "$HAS_DSC" = true ] && echo "exists" || echo "not found")"
log_info "  modelsAsService:    $([ "$HAS_MAAS_MANAGED" = true ] && echo "Managed" || echo "not managed")"
log_info "  PostgreSQL:         $([ "$HAS_POSTGRES" = true ] && echo "running" || echo "not deployed")"
log_info "  maas-api:           $([ "$HAS_MAAS_API" = true ] && echo "running" || echo "not deployed")"
log_info "  Tenant CR:          $([ "$HAS_TENANT" = true ] && echo "ready" || echo "not found")"
log_info "  MetalLB operator:   $([ "$HAS_METALLB" = true ] && echo "installed" || echo "not found")"
log_info "  Models deployed:    $([ "$HAS_MODELS" = true ] && echo "yes" || echo "no")"

if [ "$DISCONNECTED" = true ]; then
    log_info "  Mode:               DISCONNECTED (air-gapped)"
    if [ "$WITH_EXTERNAL_MODELS" = true ]; then
        log_warn "External models require internet - disabling Phase 8 in disconnected mode"
        WITH_EXTERNAL_MODELS=false
    fi
fi

# Determine which phases will run
PHASES_TO_RUN=""
should_run 1 && PHASES_TO_RUN="$PHASES_TO_RUN 1"
should_run 2 && PHASES_TO_RUN="$PHASES_TO_RUN 2"
should_run 3 && PHASES_TO_RUN="$PHASES_TO_RUN 3"
should_run 4 && PHASES_TO_RUN="$PHASES_TO_RUN 4"
should_run 5 && [ "$SKIP_MODELS" = false ] && PHASES_TO_RUN="$PHASES_TO_RUN 5"
should_run 6 && [ "$SKIP_VERIFY" = false ] && PHASES_TO_RUN="$PHASES_TO_RUN 6"
should_run 7 && [ "$WITH_OBSERVABILITY" = true ] && PHASES_TO_RUN="$PHASES_TO_RUN 7"
should_run 8 && [ "$WITH_EXTERNAL_MODELS" = true ] && PHASES_TO_RUN="$PHASES_TO_RUN 8"

echo ""
log_info "Phases to run:${PHASES_TO_RUN:- (none)}"

# =============================================================================
# Phase 1: Operators
# =============================================================================
if should_run 1; then
    log_phase 1 "Operators"

    if [ "$HAS_RHOAI_CSV" = true ] && [ "$HAS_RHCL_CSV" = true ]; then
        log_info "Required operators already installed, skipping"
    else
        RESTORE_SUB=false
        if [ "$IS_35_PLUS" = false ] && [ "$HAS_RHOAI_CSV" != true ]; then
            sed -i.bak 's/channel: stable-3.x/channel: stable-3.4/' \
                "$MANIFESTS_DIR/01-prerequisites/operators/rhoai-operator/subscription.yaml"
            log_info "Patched RHOAI subscription to channel: stable-3.4"
            RESTORE_SUB=true
        fi

        log_info "Applying operator subscriptions..."
        # Apply each operator individually, skipping OperatorGroup if one already
        # exists in the namespace to avoid OLM conflicts (GH #99)
        for op_dir in "$MANIFESTS_DIR"/01-prerequisites/operators/*/; do
            [ -d "$op_dir" ] || continue
            for f in "$op_dir"*.yaml; do
                [ -f "$f" ] || continue
                if [ "$(basename "$f")" = "operatorgroup.yaml" ]; then
                    og_ns=$(grep 'namespace:' "$f" | awk '{print $2}')
                    if [ -n "$og_ns" ] && oc get operatorgroup -n "$og_ns" --no-headers 2>/dev/null | grep -q .; then
                        log_info "OperatorGroup already exists in $og_ns, skipping"
                        continue
                    fi
                fi
                [ "$(basename "$f")" = "kustomization.yaml" ] && continue
                run_cmd oc apply -f "$f"
            done
        done

        log_info "Waiting for operator CSVs (this may take 5-10 minutes)..."
        if [ "$DRY_RUN" = false ]; then
            for ns_label in \
                "redhat-ods-operator operators.coreos.com/rhods-operator.redhat-ods-operator" \
                "openshift-operators operators.coreos.com/rhcl-operator.openshift-operators" \
                "cert-manager-operator operators.coreos.com/openshift-cert-manager-operator.cert-manager-operator" \
                "openshift-lws-operator operators.coreos.com/leader-worker-set.openshift-lws-operator"
            do
                ns="${ns_label%% *}"
                label="${ns_label#* }"
                log_info "  Waiting for CSV in $ns..."
                # Wait for CSV to appear first (oc wait exits immediately if no resources match)
                CSV_WAIT_ELAPSED=0
                while [ $CSV_WAIT_ELAPSED -lt 900 ]; do
                    CSV_COUNT=$(oc get csv -n "$ns" -l "$label=" --no-headers 2>/dev/null | wc -l | tr -d ' ')
                    [ "$CSV_COUNT" -gt 0 ] && break
                    sleep 10
                    CSV_WAIT_ELAPSED=$((CSV_WAIT_ELAPSED + 10))
                    [ $((CSV_WAIT_ELAPSED % 60)) -eq 0 ] && log_info "    Still waiting for CSV to appear in $ns... (${CSV_WAIT_ELAPSED}s)"
                done
                if [ $CSV_WAIT_ELAPSED -ge 900 ]; then
                    log_error "  CSV in $ns never appeared within 900s - aborting (re-run with --from-phase 1 after manual check)"
                    exit 1
                fi
                oc wait csv -n "$ns" -l "$label=" \
                    --for=jsonpath='{.status.phase}'=Succeeded --timeout=900s 2>/dev/null || \
                    { log_error "  CSV in $ns did not reach Succeeded within 900s - aborting (re-run with --from-phase 1 after manual check)"; exit 1; }
            done
        else
            log_info "[DRY RUN] Would wait for operator CSVs"
        fi
        log_info "All operator CSVs ready"

        if [ "$DISCONNECTED" = true ] && [ "$DRY_RUN" = false ]; then
            log_step "Patching RHCL subscription with RELATED_IMAGE_WASMSHIM for disconnected..."
            WASM_IMAGE=$(oc get csv -n openshift-operators \
                -l operators.coreos.com/rhcl-operator.openshift-operators \
                -o jsonpath='{range .items[0].spec.install.spec.deployments[0].spec.template.spec.containers[0].env[*]}{.name}={.value}{"\n"}{end}' 2>/dev/null \
                | grep RELATED_IMAGE_WASMSHIM | cut -d= -f2)
            if [ -n "$WASM_IMAGE" ]; then
                WASM_DIGEST=$(echo "$WASM_IMAGE" | grep -o 'sha256:.*')
                RHCL_MIRROR=$(oc get imageDigestMirrorSet -o json 2>/dev/null | \
                    python3 -c "
import json,sys
data=json.load(sys.stdin)
for item in data.get('items',[]):
    for m in item.get('spec',{}).get('imageDigestMirrors',[]):
        if 'rhcl-1' in m.get('source',''):
            print(m['mirrors'][0]); sys.exit(0)
" 2>/dev/null)
                if [ -n "$RHCL_MIRROR" ] && [ -n "$WASM_DIGEST" ]; then
                    WASM_MIRROR="${RHCL_MIRROR}/wasm-shim-rhel9@${WASM_DIGEST}"
                    CURRENT_WASM=$(oc get subscription rhcl-operator -n openshift-operators \
                        -o jsonpath='{.spec.config.env[?(@.name=="RELATED_IMAGE_WASMSHIM")].value}' 2>/dev/null)
                    if [ "$CURRENT_WASM" != "$WASM_MIRROR" ]; then
                        oc patch subscription rhcl-operator -n openshift-operators --type=merge -p "{
                          \"spec\": {
                            \"config\": {
                              \"env\": [{
                                \"name\": \"RELATED_IMAGE_WASMSHIM\",
                                \"value\": \"${WASM_MIRROR}\"
                              }]
                            }
                          }
                        }"
                        log_info "  WASM shim redirected to: $WASM_MIRROR"
                        log_info "  Waiting for RHCL operator pod to restart..."
                        sleep 5
                        oc wait pod -n openshift-operators -l app.kubernetes.io/name=kuadrant-operator \
                            --for=condition=Ready --timeout=120s 2>/dev/null || true
                    else
                        log_info "  WASM shim already patched, skipping"
                    fi
                else
                    log_warn "  Could not discover mirror registry from IDMS - patch RELATED_IMAGE_WASMSHIM manually (see Phase 0 docs)"
                fi
            else
                log_warn "  Could not find RELATED_IMAGE_WASMSHIM in RHCL CSV - WASM shim may fail on disconnected"
            fi
        fi
        if [ "${RESTORE_SUB:-false}" = true ]; then
            mv "$MANIFESTS_DIR/01-prerequisites/operators/rhoai-operator/subscription.yaml.bak" \
               "$MANIFESTS_DIR/01-prerequisites/operators/rhoai-operator/subscription.yaml"
            run_cmd oc patch sub rhods-operator -n redhat-ods-operator \
                --type merge -p '{"spec":{"channel":"stable-3.x"}}'
            log_info "Restored RHOAI subscription to channel: stable-3.x"
        fi
    fi
fi

# =============================================================================
# Phase 2: Platform Configuration
# =============================================================================
if should_run 2; then
    log_phase 2 "Platform Configuration"

    # Step 1: Kuadrant + Authorino TLS (per RHOAI 3.4 docs section 1.4)
    if [ "$HAS_KUADRANT" = true ]; then
        log_info "Kuadrant already configured, skipping"
    else
        log_step "Creating kuadrant-system namespace and service annotation..."
        run_cmd oc apply -f "$MANIFESTS_DIR/02-platform-config/kuadrant/namespace.yaml"
        run_cmd oc apply -f "$MANIFESTS_DIR/02-platform-config/kuadrant/service-annotation.yaml"

        log_step "Creating Kuadrant CR..."
        run_cmd oc apply -f "$MANIFESTS_DIR/02-platform-config/kuadrant/kuadrant.yaml"

        if [ "$DRY_RUN" = false ]; then
            if oc wait --for=condition=Ready kuadrant/kuadrant -n kuadrant-system --timeout=60s 2>/dev/null; then
                log_info "Kuadrant: Ready"
            else
                KUADRANT_REASON=$(oc get kuadrant kuadrant -n kuadrant-system \
                    -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}' 2>/dev/null || echo "")
                if [ "$KUADRANT_REASON" = "MissingDependency" ]; then
                    log_warn "Kuadrant reports MissingDependency - expected on fresh install (Istio not yet installed via GatewayClass)"
                    log_info "Kuadrant will be reconciled after GatewayClass creates the Istio provider (Step 7)"
                else
                    log_error "Kuadrant did not become Ready (reason: $KUADRANT_REASON) - check: oc get kuadrant kuadrant -n kuadrant-system -o yaml"
                    exit 1
                fi
            fi
        else
            log_info "[DRY RUN] Would wait for Kuadrant Ready"
        fi

        if oc get authorino authorino -n kuadrant-system &>/dev/null 2>&1; then
            log_step "Patching Authorino CR to enable TLS listener (docs section 1.4, step 2)..."
            if [ "$DRY_RUN" = true ]; then
                log_info "[DRY RUN] oc patch authorino authorino -n kuadrant-system --type=merge (enable TLS + certSecretRef)"
            else
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
                log_info "Authorino TLS listener enabled with certSecretRef: authorino-server-cert"
            fi

            log_step "Configuring Authorino TLS env vars (docs section 1.4, step 3)..."
            run_cmd oc -n kuadrant-system set env deployment/authorino \
                SSL_CERT_FILE=/etc/ssl/certs/openshift-service-ca/service-ca-bundle.crt \
                REQUESTS_CA_BUNDLE=/etc/ssl/certs/openshift-service-ca/service-ca-bundle.crt
            log_info "Authorino SSL env vars set"

            if [ "$DRY_RUN" = false ]; then
                oc get secret authorino-server-cert -n kuadrant-system &>/dev/null && \
                    log_info "Authorino TLS cert generated" || \
                    log_warn "Authorino TLS cert not yet available"
            fi
        else
            log_info "Authorino CR not yet available (Kuadrant waiting for Istio) - will configure TLS in Phase 3"
        fi
    fi

    # Step 2: User Workload Monitoring
    if [ "$HAS_UWM" = true ]; then
        log_info "User Workload Monitoring already enabled, skipping"
    else
        log_step "Enabling User Workload Monitoring (REQUIRED for MaaS)..."
        run_cmd oc apply -k "$MANIFESTS_DIR/02-platform-config/uwm/"
        log_info "UWM configured  - prometheus-user-workload pods will start shortly"
    fi

    # Step 3: GatewayClass
    if [ "$HAS_GATEWAY_CLASS" = true ]; then
        log_info "GatewayClass openshift-default already exists, skipping"
    else
        log_step "Creating GatewayClass..."
        run_cmd oc apply -f "$MANIFESTS_DIR/02-platform-config/gatewayclass.yaml"
        wait_for "GatewayClass accepted (openshift-ingress provisions Istio)" 300 \
            oc wait gatewayclass openshift-default \
            --for=jsonpath='{.status.conditions[?(@.type=="Accepted")].status}'=True
    fi

    # Step 4: Gateway
    if [ "$HAS_GATEWAY" = true ]; then
        log_info "Gateway maas-default-gateway already exists, skipping"
    else
        log_step "Rendering and applying Gateway..."
        GATEWAY_TEMPLATE="$MANIFESTS_DIR/02-platform-config/gateway.yaml.tmpl"
        if [ ! -f "$GATEWAY_TEMPLATE" ]; then
            log_error "Gateway template not found: $GATEWAY_TEMPLATE"
            exit 1
        fi
        log_info "Rendering with CLUSTER_DOMAIN=${CLUSTER_DOMAIN}, CERT_NAME=${CERT_NAME}, MAAS_HOSTNAME=${MAAS_HOSTNAME}"
        export CLUSTER_DOMAIN CERT_NAME MAAS_HOSTNAME
        # Apply gateway resource ConfigMap first (sets 2Gi memory limit via parametersRef)
        run_cmd oc apply -f "$MANIFESTS_DIR/02-platform-config/gateway-resources.yaml"
        if [ "$DRY_RUN" = true ]; then
            log_info "[DRY RUN] envsubst < gateway.yaml.tmpl | oc apply -f -"
        else
            envsubst '${CLUSTER_DOMAIN} ${CERT_NAME} ${MAAS_HOSTNAME}' < "$GATEWAY_TEMPLATE" | oc apply -f -
        fi
        if [ "$DRY_RUN" = false ]; then
            if ! oc wait gateway/maas-default-gateway -n openshift-ingress --for=condition=Programmed --timeout=120s 2>/dev/null; then
                GW_REASON=$(oc get gateway maas-default-gateway -n openshift-ingress \
                    -o jsonpath='{.status.conditions[?(@.type=="Programmed")].reason}' 2>/dev/null || echo "")
                if [ "$GW_REASON" = "AddressNotAssigned" ]; then
                    log_warn "Gateway LoadBalancer address pending (no cloud LB provisioner)"

                    # Non-cloud clusters need MetalLB to provision LB IPs
                    if [ "$IS_CLOUD_PLATFORM" = false ]; then
                        log_step "Non-cloud platform detected  - installing MetalLB..."

                        if [ "$HAS_METALLB" = false ]; then
                            log_info "Installing MetalLB operator..."
                            # Apply MetalLB resources individually, skip OG if one exists (GH #99)
                            for f in "$MANIFESTS_DIR"/01-prerequisites/metallb/*.yaml; do
                                [ -f "$f" ] || continue
                                [ "$(basename "$f")" = "kustomization.yaml" ] && continue
                                [ "$(basename "$f")" = "metallb.yaml" ] && continue
                                if [ "$(basename "$f")" = "operatorgroup.yaml" ]; then
                                    if oc get operatorgroup -n metallb-system --no-headers 2>/dev/null | grep -q .; then
                                        log_info "OperatorGroup already exists in metallb-system, skipping"
                                        continue
                                    fi
                                fi
                                oc apply -f "$f"
                            done
                            log_info "Waiting for MetalLB CSV..."
                            METALLB_TIMEOUT=120
                            METALLB_ELAPSED=0
                            while [ $METALLB_ELAPSED -lt $METALLB_TIMEOUT ]; do
                                METALLB_CSV_STATUS=$(oc get csv -n metallb-system --no-headers 2>/dev/null | grep metallb-operator | awk '{print $NF}' || echo "")
                                if [ "$METALLB_CSV_STATUS" = "Succeeded" ]; then
                                    break
                                fi
                                sleep 10
                                METALLB_ELAPSED=$((METALLB_ELAPSED + 10))
                            done
                            if [ "$METALLB_CSV_STATUS" != "Succeeded" ]; then
                                log_warn "MetalLB CSV did not reach Succeeded within ${METALLB_TIMEOUT}s (status: ${METALLB_CSV_STATUS:-unknown})"
                            else
                                log_info "MetalLB operator: Succeeded"
                            fi
                        fi

                        # Create MetalLB CR if needed
                        if ! oc get metallb metallb -n metallb-system &>/dev/null; then
                            log_info "Creating MetalLB CR..."
                            oc apply -f "$MANIFESTS_DIR/01-prerequisites/metallb/metallb.yaml"
                            oc wait --for=jsonpath='{.status.conditions[?(@.type=="Available")].status}'=True \
                                metallb/metallb -n metallb-system --timeout=120s 2>/dev/null || \
                                log_warn "MetalLB CR did not become Available"
                        fi

                        # Create IPAddressPool + L2Advertisement if needed
                        if ! oc get ipaddresspool maas-pool -n metallb-system &>/dev/null; then
                            NODE_IP=$(oc get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "")
                            if [ -n "$NODE_IP" ]; then
                                METALLB_IP=$(echo "$NODE_IP" | awk -F. '{printf "%s.%s.%s.%d", $1, $2, $3, $4+1}')
                                METALLB_IP_RANGE="${METALLB_IP}-${METALLB_IP}"
                                log_info "Creating MetalLB IPAddressPool: ${METALLB_IP_RANGE} (node IP: ${NODE_IP})"
                                export METALLB_IP_RANGE
                                envsubst '${METALLB_IP_RANGE}' < "$MANIFESTS_DIR/03-maas-platform/openshift-gateway-setup/metallb-config.yaml" | oc apply -f -
                            else
                                log_warn "Cannot detect node IP for MetalLB pool"
                            fi
                        fi

                        # Wait for Gateway to pick up the MetalLB address
                        log_info "Waiting for Gateway to become Programmed with MetalLB address..."
                        if oc wait gateway/maas-default-gateway -n openshift-ingress --for=condition=Programmed --timeout=60s 2>/dev/null; then
                            log_info "Gateway: Programmed (MetalLB)"
                        else
                            log_warn "Gateway still not Programmed after MetalLB setup"
                        fi
                    fi

                    # Create passthrough Route as fallback (works for both MetalLB and non-MetalLB)
                    log_info "Creating passthrough Route as fallback..."
                    ROUTE_TMPL="$MANIFESTS_DIR/03-maas-platform/openshift-gateway-setup/route.yaml.tmpl"
                    if [ -f "$ROUTE_TMPL" ]; then
                        export CLUSTER_DOMAIN MAAS_HOSTNAME
                        envsubst '${CLUSTER_DOMAIN} ${MAAS_HOSTNAME}' < "$ROUTE_TMPL" | oc apply -f -
                        log_info "Route maas-default-gateway-https created  - traffic routed via OpenShift ingress"
                    else
                        log_warn "Route template not found: $ROUTE_TMPL"
                    fi
                else
                    log_warn "Gateway not Programmed (reason: ${GW_REASON:-unknown})"
                fi
            else
                log_info "Gateway: Programmed"
            fi
        else
            log_info "[DRY RUN] Would wait for Gateway Programmed"
        fi
    fi

    # Step 5: Annotate Gateway for Authorino TLS bootstrap (docs section 1.4, step 4)
    EXISTING_ANNOTATION=$(oc get gateway maas-default-gateway -n openshift-ingress \
        -o jsonpath='{.metadata.annotations.security\.opendatahub\.io/authorino-tls-bootstrap}' 2>/dev/null || echo "")
    if [ "$EXISTING_ANNOTATION" != "true" ]; then
        log_step "Annotating Gateway for Authorino TLS bootstrap (docs section 1.4, step 4)..."
        run_cmd oc annotate gateway maas-default-gateway -n openshift-ingress \
            security.opendatahub.io/authorino-tls-bootstrap="true" --overwrite
        log_info "Gateway authorino-tls-bootstrap annotation applied"
    fi

    # Step 6: On disconnected AWS, patch Gateway for internal LB
    if [ "$DISCONNECTED" = true ] && [ "$PLATFORM_TYPE" = "AWS" ]; then
        CURRENT_LB=$(oc get svc maas-default-gateway-openshift-default -n openshift-ingress \
            -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
        if [[ "$CURRENT_LB" != internal-* ]] && [ -n "$CURRENT_LB" ]; then
            log_step "Patching Gateway for internal LB (disconnected AWS)..."
            run_cmd oc patch gateway maas-default-gateway -n openshift-ingress --type=merge -p '{
              "spec": {
                "infrastructure": {
                  "annotations": {
                    "service.beta.kubernetes.io/aws-load-balancer-internal": "true"
                  }
                }
              }
            }'
            log_info "Deleting gateway service to force internal NLB recreation..."
            oc delete svc maas-default-gateway-openshift-default -n openshift-ingress 2>/dev/null || true
            SVC_WAIT=0
            while [ $SVC_WAIT -lt 60 ]; do
                NEW_LB=$(oc get svc maas-default-gateway-openshift-default -n openshift-ingress \
                    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
                if [[ "$NEW_LB" == internal-* ]]; then
                    log_info "Internal NLB ready: $NEW_LB"
                    break
                fi
                sleep 5
                SVC_WAIT=$((SVC_WAIT + 5))
            done
            if [[ "$NEW_LB" != internal-* ]]; then
                log_warn "Internal NLB not ready after 60s - DNS may take longer to propagate"
            fi
        else
            log_info "Gateway LB already internal, skipping"
        fi
    fi

    # Step 7: Ensure Kuadrant sees the Gateway API provider (Istio race fix)
    # On fresh installs, Kuadrant CR was created before GatewayClass (which provisions Istio).
    # On pre-existing clusters, Kuadrant may have been installed before Istio too.
    # Either way, restart the operator if it still reports MissingDependency now that Gateway is up.
    if [ "$DRY_RUN" = false ]; then
        KUADRANT_READY=$(oc get kuadrant kuadrant -n kuadrant-system \
            -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
        if [ "$KUADRANT_READY" != "True" ]; then
            KUADRANT_REASON=$(oc get kuadrant kuadrant -n kuadrant-system \
                -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}' 2>/dev/null || echo "")
            if [ "$KUADRANT_REASON" = "MissingDependency" ]; then
                log_warn "Kuadrant reports MissingDependency after Gateway setup - restarting operator pod..."
                KUADRANT_POD=$(oc get pods -n openshift-operators --no-headers 2>/dev/null \
                    | grep kuadrant-operator-controller | awk '{print $1}' | head -1)
                if [ -n "$KUADRANT_POD" ]; then
                    oc delete pod "$KUADRANT_POD" -n openshift-operators 2>/dev/null || true
                    sleep 10
                    oc wait kuadrant/kuadrant -n kuadrant-system --for=condition=Ready --timeout=120s 2>/dev/null || \
                        { log_error "Kuadrant did not become Ready after Gateway setup and operator restart"; exit 1; }
                    log_info "Kuadrant: Ready (after operator restart)"
                fi
            else
                log_warn "Kuadrant not Ready (reason: $KUADRANT_REASON) - may need manual investigation"
            fi
        fi
    fi

    # Label namespace for Gateway route binding (best practice: least privilege)
    # For 3.5+, skip here - redhat-ai-gateway-infra does not exist yet (created in Phase 4)
    # and the operator auto-labels it. For 3.4, redhat-ods-applications already exists.
    if [ "$IS_35_PLUS" = false ]; then
        oc label namespace "$MAAS_API_NS" maas.opendatahub.io/gateway-access=true --overwrite 2>/dev/null || true
    fi
fi

# =============================================================================
# Phase 3: MaaS Platform (PostgreSQL + secrets before DSC enables modelsAsService)
# =============================================================================
if should_run 3; then
    log_phase 3 "MaaS Platform"

    # Step 1: PostgreSQL secrets
    log_step "PostgreSQL secrets"
    if oc get secret postgres-creds -n "$NAMESPACE" &>/dev/null 2>&1; then
        log_info "postgres-creds already exists, skipping"
    else
        POSTGRES_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)
        run_cmd oc create secret generic postgres-creds \
            -n "$NAMESPACE" \
            --from-literal=POSTGRES_USER=maas \
            --from-literal=POSTGRES_DB=maas \
            --from-literal=POSTGRES_PASSWORD="$POSTGRES_PASSWORD"
        run_cmd oc create secret generic maas-db-config \
            -n "$NAMESPACE" \
            --from-literal=DB_CONNECTION_URL="postgresql://maas:${POSTGRES_PASSWORD}@postgres.${NAMESPACE}.svc:5432/maas?sslmode=disable"
        log_info "PostgreSQL secrets created"

        if [ "$IS_35_PLUS" = true ]; then
            oc create namespace "$GATEWAY_INFRA_NS" --dry-run=client -o yaml | oc apply -f - >/dev/null 2>&1 || true
            run_cmd oc create secret generic maas-db-config \
                -n "$GATEWAY_INFRA_NS" \
                --from-literal=DB_CONNECTION_URL="postgresql://maas:${POSTGRES_PASSWORD}@postgres.${NAMESPACE}.svc:5432/maas?sslmode=disable"
            log_info "Mirrored maas-db-config to ${GATEWAY_INFRA_NS} (RHOAI 3.5+ maas-api location)"
        fi
    fi

    # Step 2: PostgreSQL deployment
    log_step "PostgreSQL deployment"
    if [ "$HAS_POSTGRES" = true ]; then
        log_info "PostgreSQL already deployed, skipping"
    else
        run_cmd oc apply -k "$MANIFESTS_DIR/03-maas-platform/"
        wait_for "PostgreSQL available" 120 \
            oc wait --for=condition=Available deployment/postgres -n "$NAMESPACE"
    fi

    # Step 3: Ensure Gateway + TLS exists (may have been created in Phase 2)
    if ! oc get gateway maas-default-gateway -n openshift-ingress &>/dev/null 2>&1; then
        log_step "Rendering and applying Gateway (not created in Phase 2)..."
        export CLUSTER_DOMAIN CERT_NAME MAAS_HOSTNAME
        run_cmd oc apply -f "$MANIFESTS_DIR/02-platform-config/gateway-resources.yaml"
        if [ "$DRY_RUN" = true ]; then
            log_info "[DRY RUN] envsubst < gateway.yaml.tmpl | oc apply -f -"
        else
            envsubst '${CLUSTER_DOMAIN} ${CERT_NAME} ${MAAS_HOSTNAME}' < "$MANIFESTS_DIR/02-platform-config/gateway.yaml.tmpl" | oc apply -f -
        fi
    fi
    # Ensure Authorino TLS is configured (may have been done in Phase 2)
    AUTHORINO_TLS=$(oc get authorino authorino -n kuadrant-system \
        -o jsonpath='{.spec.listener.tls.enabled}' 2>/dev/null || echo "")
    if [ "$AUTHORINO_TLS" != "true" ]; then
        log_step "Patching Authorino CR for TLS (docs section 1.4, step 2)..."
        run_cmd oc patch authorino authorino -n kuadrant-system --type=merge --patch '{
          "spec": {"listener": {"tls": {"enabled": true, "certSecretRef": {"name": "authorino-server-cert"}}}}
        }'
    fi
    EXISTING_ENVS=$(oc get deployment authorino -n kuadrant-system \
        -o jsonpath='{.spec.template.spec.containers[0].env[*].name}' 2>/dev/null || echo "")
    if ! echo "$EXISTING_ENVS" | grep SSL_CERT_FILE >/dev/null 2>&1; then
        log_step "Configuring Authorino TLS env vars (docs section 1.4, step 3)..."
        run_cmd oc -n kuadrant-system set env deployment/authorino \
            SSL_CERT_FILE=/etc/ssl/certs/openshift-service-ca/service-ca-bundle.crt \
            REQUESTS_CA_BUNDLE=/etc/ssl/certs/openshift-service-ca/service-ca-bundle.crt
    fi
    EXISTING_ANNOTATION=$(oc get gateway maas-default-gateway -n openshift-ingress \
        -o jsonpath='{.metadata.annotations.security\.opendatahub\.io/authorino-tls-bootstrap}' 2>/dev/null || echo "")
    if [ "$EXISTING_ANNOTATION" != "true" ]; then
        log_step "Annotating Gateway for TLS bootstrap (docs section 1.4, step 4)..."
        run_cmd oc annotate gateway maas-default-gateway -n openshift-ingress \
            security.opendatahub.io/authorino-tls-bootstrap="true" --overwrite
    fi
fi

# =============================================================================
# Phase 4: RHOAI Configuration (DSC enables MaaS after DB exists)
# =============================================================================
if should_run 4; then
    log_phase 4 "RHOAI Configuration"

    if [ "$HAS_MAAS_MANAGED" = true ] && \
       { [ "$IS_35_PLUS" = false ] || [ "$MAAS_STATE_35" = "Managed" ]; }; then
        log_info "DSC already has MaaS: Managed, skipping"
    else
        log_step "Applying DSC and DSCI..."
        run_cmd oc apply -f "$MANIFESTS_DIR/04-rhoai-config/dscinitialization.yaml"
        if [ "$IS_35_PLUS" = true ]; then
            log_info "Using RHOAI 3.5+ DSC (aigateway.modelsAsAService)"
            run_cmd oc apply -f "$MANIFESTS_DIR/04-rhoai-config/datasciencecluster.yaml"
        else
            log_info "Using RHOAI 3.4 DSC (kserve.modelsAsService)"
            run_cmd oc apply -f "$MANIFESTS_DIR/04-rhoai-config/datasciencecluster-34.yaml"
        fi
        log_info "DSC/DSCI applied"

        if [ "$DRY_RUN" = false ]; then
            log_info "Waiting for KserveReady condition (up to 5 minutes)..."
            oc wait --for=jsonpath='{.status.conditions[?(@.type=="KserveReady")].status}'=True \
                datasciencecluster/default-dsc --timeout=300s 2>/dev/null || \
                log_warn "KserveReady did not become True within 300s"

            if [ "$IS_35_PLUS" = false ]; then
                log_info "Waiting for ModelControllerReady condition..."
                oc wait --for=jsonpath='{.status.conditions[?(@.type=="ModelControllerReady")].status}'=True \
                    datasciencecluster/default-dsc --timeout=300s 2>/dev/null || \
                    log_warn "ModelControllerReady did not become True within 300s"
            fi

            wait_for_crd "maasmodelrefs.maas.opendatahub.io" 300
        fi

        log_step "Applying HardwareProfile..."
        wait_for_crd "hardwareprofiles.infrastructure.opendatahub.io" 300
        run_cmd oc apply -f "$MANIFESTS_DIR/04-rhoai-config/hardwareprofile.yaml"

        log_step "Applying OdhDashboardConfig..."
        wait_for_crd "odhdashboardconfigs.opendatahub.io" 300
        run_cmd oc apply -f "$MANIFESTS_DIR/04-rhoai-config/odh-dashboard-config.yaml"
        if [ "$DRY_RUN" = false ]; then
            for _attempt in 1 2 3; do
                sleep 10
                MAAS_FLAG=$(oc get odhdashboardconfig odh-dashboard-config -n "$NAMESPACE" \
                    -o jsonpath='{.spec.dashboardConfig.modelAsService}' 2>/dev/null || echo "")
                if [ "$MAAS_FLAG" = "true" ]; then break; fi
                log_warn "Dashboard config flags overridden by operator — re-applying (attempt $_attempt)..."
                oc apply -f "$MANIFESTS_DIR/04-rhoai-config/odh-dashboard-config.yaml" 2>/dev/null || true
            done
        fi
        log_info "Dashboard config applied"
    fi

    # Wait for maas-api (probes both namespaces - 3.5+ uses redhat-ai-gateway-infra)
    log_step "Waiting for maas-api deployment"
    if [ "$HAS_MAAS_API" = true ]; then
        log_info "maas-api already running in ${MAAS_API_NS}"
    elif [ "$DRY_RUN" = false ]; then
        TIMEOUT=300
        ELAPSED=0
        MAAS_API_FOUND=false
        while [ $ELAPSED -lt $TIMEOUT ]; do
            for _ns in "$GATEWAY_INFRA_NS" "$NAMESPACE"; do
                if oc get deployment maas-api -n "$_ns" &>/dev/null; then
                    MAAS_API_NS="$_ns"
                    MAAS_API_FOUND=true
                    break
                fi
            done
            if [ "$MAAS_API_FOUND" = true ]; then
                log_info "maas-api deployment found in ${MAAS_API_NS}"
                oc rollout status deployment/maas-api -n "$MAAS_API_NS" --timeout=180s 2>/dev/null || \
                    log_warn "maas-api rollout did not complete within 180s"
                break
            fi
            sleep 10
            ELAPSED=$((ELAPSED + 10))
            if [ $((ELAPSED % 60)) -eq 0 ]; then
                log_info "Still waiting for maas-api... (${ELAPSED}s)"
            fi
        done
        [ $ELAPSED -ge $TIMEOUT ] && log_warn "maas-api not found after ${TIMEOUT}s  - operator may still be reconciling"
    fi

    # Ensure gateway-access label on MaaS API namespace (safety net for 3.5+)
    if [ "$IS_35_PLUS" = true ] && oc get namespace "$MAAS_API_NS" &>/dev/null; then
        oc label namespace "$MAAS_API_NS" maas.opendatahub.io/gateway-access=true --overwrite 2>/dev/null || true
    fi

    # Verify MaaS readiness (3.5+ uses Config CR, 3.4 uses Tenant CR)
    if [ "$DRY_RUN" = false ]; then
        if [ "$IS_35_PLUS" = true ]; then
            if oc get configs.maas.opendatahub.io default &>/dev/null; then
                log_info "MaaS Config CR: exists"
            else
                log_warn "MaaS Config CR not found yet"
            fi
        else
            TENANT_READY=$(oc get tenant default-tenant -n models-as-a-service \
                -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
            if [ "$TENANT_READY" = "True" ]; then
                log_info "Tenant CR: Ready"
            else
                log_warn "Tenant CR not Ready yet (status: ${TENANT_READY:-not found})"
            fi
        fi
    fi

    # Health check (in disconnected mode, external ELB may be unreachable - try NodePort fallback)
    if [ "$DRY_RUN" = false ]; then
        HTTP_CODE=$(curl -sk --connect-timeout 10 --max-time 15 -o /dev/null -w '%{http_code}' \
            "https://${MAAS_HOSTNAME}/maas-api/health" 2>/dev/null) || true
        [ -z "$HTTP_CODE" ] && HTTP_CODE="000"
        if [ "$HTTP_CODE" = "200" ]; then
            log_info "Health endpoint: HTTP 200"
        elif [ "$HTTP_CODE" = "401" ]; then
            log_info "Health endpoint: HTTP 401 (auth working, health may need token)"
        elif [ "$HTTP_CODE" = "000" ] && [ "$DISCONNECTED" = true ]; then
            log_warn "Health endpoint unreachable via external URL (expected in disconnected mode)"
            GW_NODEPORT=$(oc get svc maas-default-gateway-openshift-default -n openshift-ingress \
                -o jsonpath='{.spec.ports[?(@.port==443)].nodePort}' 2>/dev/null || echo "")
            NODE_INT_IP=$(oc get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "")
            if [ -n "$GW_NODEPORT" ] && [ -n "$NODE_INT_IP" ]; then
                NP_CODE=$(curl -sk --connect-timeout 10 --max-time 15 -o /dev/null -w '%{http_code}' \
                    --resolve "${MAAS_HOSTNAME}:${GW_NODEPORT}:${NODE_INT_IP}" \
                    "https://${MAAS_HOSTNAME}:${GW_NODEPORT}/maas-api/health" 2>/dev/null) || true
                [ -z "$NP_CODE" ] && NP_CODE="000"
                if [ "$NP_CODE" = "200" ] || [ "$NP_CODE" = "401" ]; then
                    log_info "Health endpoint: HTTP ${NP_CODE} (via NodePort ${GW_NODEPORT})"
                else
                    log_warn "Health endpoint via NodePort: HTTP ${NP_CODE}"
                fi
            fi
        else
            log_warn "Health endpoint: HTTP ${HTTP_CODE} (may need DNS propagation)"
        fi
    fi
fi

# =============================================================================
# Phase 5: Deploy Model
# =============================================================================
if should_run 5 && [ "$SKIP_MODELS" = false ]; then
    log_phase 5 "Deploy Model"

    if [ "$HAS_MODELS" = true ]; then
        log_info "Models already deployed in llm namespace:"
        oc get llminferenceservice -n llm --no-headers 2>/dev/null || true
        log_info "Skipping model deployment (use --from-phase 5 to force)"
    else
        # Auto-detect model
        if [ "$MODEL" = "auto" ]; then
            log_step "Auto-detecting GPU capabilities..."
            GPU_MEMORY=$(oc get nodes -o jsonpath='{.items[*].metadata.labels.nvidia\.com/gpu\.memory}' 2>/dev/null \
                | tr ' ' '\n' | sort -rn | head -1)
            if [ -z "$GPU_MEMORY" ]; then
                if [ "$DISCONNECTED" = true ]; then
                    MODEL="simulator-disconnected"
                    log_info "No GPU nodes detected (disconnected) -> simulator-disconnected"
                else
                    MODEL="simulator"
                    log_info "No GPU nodes detected -> simulator"
                fi
            elif [ "$GPU_MEMORY" -ge 40960 ] 2>/dev/null; then
                MODEL="gpt-oss-20b"
                log_info "GPU VRAM: ${GPU_MEMORY} MiB (>= 40960) -> gpt-oss-20b"
            elif [ "$GPU_MEMORY" -ge 16384 ] 2>/dev/null; then
                MODEL="gemma"
                log_info "GPU VRAM: ${GPU_MEMORY} MiB (>= 16384) -> gemma"
            else
                MODEL="granite-tiny-gpu"
                log_info "GPU VRAM: ${GPU_MEMORY} MiB (< 16384) -> granite-tiny-gpu"
            fi
        fi

        VALID_MODELS="simulator simulator-disconnected granite-tiny-gpu gpt-oss-20b gemma"
        if ! echo "$VALID_MODELS" | grep -qw "$MODEL"; then
            log_error "Unknown model: $MODEL (valid: $VALID_MODELS)"
            exit 1
        fi

        MODEL_DIR="$MANIFESTS_DIR/05-maas-models/$MODEL"
        if [ ! -d "$MODEL_DIR" ]; then
            log_error "Model directory not found: $MODEL_DIR"
            exit 1
        fi

        log_step "Deploying model: $MODEL"
        if ! oc get namespace llm &>/dev/null; then
            run_cmd oc create namespace llm
        fi
        oc label namespace llm opendatahub.io/generated-namespace=true --overwrite 2>/dev/null || true
        oc label namespace llm maas.opendatahub.io/gateway-access=true --overwrite 2>/dev/null || true
        oc label namespace llm opendatahub.io/dashboard=true --overwrite 2>/dev/null || true
        run_cmd oc apply -k "$MODEL_DIR/"
        log_info "Model manifests applied"

        if [ "$DRY_RUN" = false ]; then
            # Wait for pods
            log_info "Waiting for model pods (up to 10 minutes for GPU models)..."
            TIMEOUT=600
            ELAPSED=0
            XET_PATCHED=false
            while [ $ELAPSED -lt $TIMEOUT ]; do
                POD_COUNT=$(oc get pods -n llm --no-headers 2>/dev/null | wc -l | tr -d ' ')
                if [ "$POD_COUNT" -gt 0 ]; then
                    NOT_READY=$(oc get pods -n llm --no-headers 2>/dev/null \
                        | { grep -v "Running\|Completed" || true; } | wc -l | tr -d ' ')
                    if [ "$NOT_READY" -eq 0 ]; then
                        log_info "All model pods Running"
                        break
                    fi
                    # HuggingFace Xet workaround: if pods stuck in Init for >120s, disable Xet
                    if [ "$XET_PATCHED" = false ] && [ $ELAPSED -ge 120 ]; then
                        INIT_STUCK=$(oc get pods -n llm --no-headers 2>/dev/null | { grep "Init:" || true; } | wc -l | tr -d ' ')
                        if [ "$INIT_STUCK" -gt 0 ]; then
                            log_warn "Pod stuck in Init - applying HF_HUB_DISABLE_XET=1 workaround"
                            for deploy in $(oc get deployment -n llm --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null); do
                                oc patch deployment "$deploy" -n llm --type=json \
                                    -p '[{"op":"add","path":"/spec/template/spec/initContainers/0/env/-","value":{"name":"HF_HUB_DISABLE_XET","value":"1"}}]' 2>/dev/null || true
                            done
                            XET_PATCHED=true
                        fi
                    fi
                fi
                sleep 10
                ELAPSED=$((ELAPSED + 10))
                [ $((ELAPSED % 60)) -eq 0 ] && log_info "  Still waiting... (${ELAPSED}s)"
            done
            [ $ELAPSED -ge $TIMEOUT ] && log_warn "Pods not all Running after ${TIMEOUT}s"

            # Wait for MaaSModelRef
            log_info "Waiting for MaaSModelRef phase=Ready..."
            TIMEOUT=300
            ELAPSED=0
            while [ $ELAPSED -lt $TIMEOUT ]; do
                PHASE=$(oc get maasmodelref -n llm -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")
                [ "$PHASE" = "Ready" ] && break
                sleep 10
                ELAPSED=$((ELAPSED + 10))
            done
            if [ "${PHASE:-}" = "Ready" ]; then
                log_info "MaaSModelRef: Ready"
            else
                log_warn "MaaSModelRef not Ready after ${TIMEOUT}s (phase: ${PHASE:-unknown})"
            fi
        fi
    fi
fi

# =============================================================================
# Phase 6: Verify
# =============================================================================
if should_run 6 && [ "$SKIP_VERIFY" = false ]; then
    log_phase 6 "Verify"

    VERIFY_SCRIPT="$MANIFESTS_DIR/06-verification/verify.sh"
    if [ ! -x "$VERIFY_SCRIPT" ]; then
        log_error "Verification script not found or not executable: $VERIFY_SCRIPT"
    elif [ "$DRY_RUN" = true ]; then
        log_info "[DRY RUN] Would run: $VERIFY_SCRIPT"
    else
        log_info "Running E2E verification..."
        if [ "$DISCONNECTED" = true ]; then
            "$VERIFY_SCRIPT" --disconnected || log_warn "Verification had failures  - check output above"
        else
            "$VERIFY_SCRIPT" || log_warn "Verification had failures  - check output above"
        fi
    fi
fi

# =============================================================================
# Phase 7: Observability (Optional)
# =============================================================================
if should_run 7 && [ "$WITH_OBSERVABILITY" = true ]; then
    log_phase 7 "Observability"

    # Tempo Operator
    log_step "Installing Tempo Operator..."
    run_cmd oc apply -k "$MANIFESTS_DIR/07-observability/tempo/"
    if [ "$DRY_RUN" = false ]; then
        log_info "Waiting for Tempo CSV..."
        TIMEOUT=300
        ELAPSED=0
        while [ $ELAPSED -lt $TIMEOUT ]; do
            TEMPO_PHASE=$(oc get csv -n openshift-tempo-operator --no-headers 2>/dev/null \
                | grep tempo-operator | awk '{print $NF}' || echo "")
            [ "$TEMPO_PHASE" = "Succeeded" ] && break
            sleep 10
            ELAPSED=$((ELAPSED + 10))
        done
        if [ "${TEMPO_PHASE:-}" = "Succeeded" ]; then
            log_info "Tempo CSV: Succeeded"
        else
            log_warn "Tempo CSV not Succeeded after ${TIMEOUT}s"
        fi
    fi

    # Red Hat build of OpenTelemetry Operator
    log_step "Installing Red Hat build of OpenTelemetry Operator..."
    run_cmd oc apply -k "$MANIFESTS_DIR/07-observability/opentelemetry/"
    if [ "$DRY_RUN" = false ]; then
        log_info "Waiting for OpenTelemetry CSV..."
        TIMEOUT=300
        ELAPSED=0
        while [ $ELAPSED -lt $TIMEOUT ]; do
            OTEL_PHASE=$(oc get csv -n openshift-opentelemetry-operator --no-headers 2>/dev/null \
                | grep opentelemetry-operator | awk '{print $NF}' || echo "")
            [ "$OTEL_PHASE" = "Succeeded" ] && break
            sleep 10
            ELAPSED=$((ELAPSED + 10))
        done
        if [ "${OTEL_PHASE:-}" = "Succeeded" ]; then
            log_info "OpenTelemetry CSV: Succeeded"
        else
            log_warn "OpenTelemetry CSV not Succeeded after ${TIMEOUT}s"
        fi
    fi

    # COO
    log_step "Installing Cluster Observability Operator..."
    run_cmd oc apply -k "$MANIFESTS_DIR/07-observability/coo/"

    if [ "$DRY_RUN" = false ]; then
        log_info "Waiting for COO CSV..."
        TIMEOUT=300
        ELAPSED=0
        while [ $ELAPSED -lt $TIMEOUT ]; do
            COO_PHASE=$(oc get csv -n openshift-cluster-observability-operator --no-headers 2>/dev/null \
                | grep cluster-observability | awk '{print $NF}' || echo "")
            [ "$COO_PHASE" = "Succeeded" ] && break
            sleep 10
            ELAPSED=$((ELAPSED + 10))
        done
        if [ "${COO_PHASE:-}" = "Succeeded" ]; then
            log_info "COO CSV: Succeeded"
        else
            log_warn "COO CSV not Succeeded after ${TIMEOUT}s"
        fi
    fi

    # DSCI monitoring config
    log_step "Enabling DSCI monitoring (metrics + traces)..."
    run_cmd oc patch dsci default-dsci --type=merge -p '{
      "spec": {
        "monitoring": {
          "namespace": "redhat-ods-monitoring",
          "metrics": {
            "replicas": 1,
            "storage": {
              "size": "5Gi",
              "retention": "90d"
            }
          },
          "traces": {
            "sampleRatio": "0.1",
            "storage": {
              "backend": "pv",
              "retention": "2160h"
            }
          }
        }
      }
    }'
    if [ "$DRY_RUN" = false ]; then
        log_info "Waiting for DSCI to reconcile..."
        oc wait --for=jsonpath='{.status.phase}'=Ready dsci/default-dsci --timeout=300s 2>/dev/null || \
            log_warn "DSCI did not reach Ready within 300s (monitoring cascade may still be provisioning)"
    fi
    log_info "DSCI monitoring configured"

    # Telemetry
    log_step "Applying Gateway telemetry..."
    run_cmd oc apply -k "$MANIFESTS_DIR/07-observability/telemetry/"
    log_info "Gateway telemetry applied"

    # Usage Dashboards with Loki (3.5+ only)
    if [ "$IS_35_PLUS" = true ]; then
        log_step "Installing Loki Operator (usage dashboards)..."
        run_cmd oc apply -k "$MANIFESTS_DIR/07-observability/loki/"
        if [ "$DRY_RUN" = false ]; then
            log_info "Waiting for Loki CSV..."
            TIMEOUT=300
            ELAPSED=0
            while [ $ELAPSED -lt $TIMEOUT ]; do
                LOKI_PHASE=$(oc get csv -n openshift-operators-redhat --no-headers 2>/dev/null \
                    | grep loki-operator | awk '{print $NF}' || echo "")
                [ "$LOKI_PHASE" = "Succeeded" ] && break
                sleep 10
                ELAPSED=$((ELAPSED + 10))
            done
            if [ "${LOKI_PHASE:-}" = "Succeeded" ]; then
                log_info "Loki CSV: Succeeded"
            else
                log_warn "Loki CSV not Succeeded after ${TIMEOUT}s"
            fi
        fi

        log_step "Deploying MinIO + LokiStack for usage logging..."
        LOKI_STORAGE_CLASS=$(oc get sc -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}' 2>/dev/null || echo "")
        if [ -z "$LOKI_STORAGE_CLASS" ]; then
            LOKI_STORAGE_CLASS="gp3-csi"
            log_warn "No default StorageClass found, using fallback: ${LOKI_STORAGE_CLASS}"
        else
            log_info "Using default StorageClass: ${LOKI_STORAGE_CLASS}"
        fi
        run_cmd oc apply -f "$MANIFESTS_DIR/07-observability/usage-logging/minio.yaml"
        run_cmd oc apply -f "$MANIFESTS_DIR/07-observability/usage-logging/minio-secret.yaml"
        if [ "$DRY_RUN" = true ]; then
            log_info "[DRY RUN] lokistack.yaml with storageClassName=${LOKI_STORAGE_CLASS}"
        else
            sed "s/storageClassName: gp3-csi/storageClassName: ${LOKI_STORAGE_CLASS}/" \
                "$MANIFESTS_DIR/07-observability/usage-logging/lokistack.yaml" | oc apply -f -
        fi

        if [ "$DRY_RUN" = false ]; then
            log_info "Waiting for LokiStack to be ready..."
            oc wait lokistack/usage -n redhat-ods-monitoring \
                --for=jsonpath='{.status.conditions[?(@.type=="Ready")].status}'=True --timeout=300s 2>/dev/null || \
                log_warn "LokiStack not ready within 300s (may still be provisioning)"
        fi

        log_step "Enabling usage logging on MaaS Config..."
        run_cmd oc patch configs.maas.opendatahub.io default --type=merge \
            -p '{"spec":{"usageLogging":true}}'
        log_info "Usage logging enabled - operator will create EnvoyFilter, OTEL Collector, and Perses dashboards"
    fi
fi

# =============================================================================
# Phase 8: External Models (Optional)
# =============================================================================
if should_run 8 && [ "$WITH_EXTERNAL_MODELS" = true ]; then
    log_phase 8 "External Models (provider: ${EXTERNAL_MODEL_PROVIDER})"

    if [ "$DISCONNECTED" = true ]; then
        log_warn "Phase 8 skipped - external models require internet access (incompatible with disconnected/air-gapped)"
    elif [ -z "$EXTERNAL_MODEL_API_KEY" ]; then
        log_warn "No external model API key provided (use --external-model-api-key or EXTERNAL_MODEL_API_KEY env var)"
        log_warn "Skipping Phase 8"
    else
        EXTMODEL_NS="external-models"

        case "$EXTERNAL_MODEL_PROVIDER" in
            openai)
                EXTMODEL_NAME="gpt-4o-mini"
                EXTMODEL_SECRET="openai-api-key"
                EXTMODEL_SUBSCRIPTION="openai-free"
                EXTMODEL_TARGET_MODEL="gpt-4o-mini"
                ;;
            gemini)
                EXTMODEL_NAME="gemini-2-5-flash"
                EXTMODEL_SECRET="gemini-api-key"
                EXTMODEL_SUBSCRIPTION="gemini-free"
                EXTMODEL_TARGET_MODEL="gemini-2.5-flash"
                ;;
            bedrock)
                EXTMODEL_NAME="aws-gpt-oss-20b"
                EXTMODEL_SECRET="bedrock-api-key"
                EXTMODEL_SUBSCRIPTION="bedrock-free"
                EXTMODEL_TARGET_MODEL="openai.gpt-oss-20b"
                ;;
            *)
                log_warn "Unknown provider '${EXTERNAL_MODEL_PROVIDER}' (supported: openai, gemini, bedrock)"
                log_warn "Skipping Phase 8"
                EXTERNAL_MODEL_API_KEY=""
                ;;
        esac

        if [ -n "$EXTERNAL_MODEL_API_KEY" ]; then
            PROVIDER_DIR="$MANIFESTS_DIR/08-external-models/${EXTERNAL_MODEL_PROVIDER}"

            if [ ! -d "$PROVIDER_DIR" ]; then
                log_warn "Manifest directory not found: $PROVIDER_DIR"
                log_warn "Skipping Phase 8"
            else
                # Create namespace
                log_step "Creating external-models namespace..."
                if oc get namespace "$EXTMODEL_NS" &>/dev/null; then
                    log_info "Namespace $EXTMODEL_NS already exists"
                else
                    run_cmd oc apply -f "${PROVIDER_DIR}/namespace.yaml"
                fi

                log_step "Creating provider credential Secret..."
                if [ "$DRY_RUN" = true ]; then
                    log_info "[DRY RUN] Would create Secret ${EXTMODEL_SECRET} in $EXTMODEL_NS"
                else
                    oc create secret generic "$EXTMODEL_SECRET" \
                        --from-literal=api-key="$EXTERNAL_MODEL_API_KEY" \
                        -n "$EXTMODEL_NS" \
                        --dry-run=client -o yaml | oc apply -f - 2>/dev/null
                    if [ "$IS_35_PLUS" = true ]; then
                        oc label secret "$EXTMODEL_SECRET" -n "$EXTMODEL_NS" \
                            inference.llm-d.ai/ipp-managed=true --overwrite 2>/dev/null
                        log_info "Secret ${EXTMODEL_SECRET} created/updated (ipp-managed label applied)"
                    else
                        oc label secret "$EXTMODEL_SECRET" -n "$EXTMODEL_NS" \
                            inference.networking.k8s.io/bbr-managed=true --overwrite 2>/dev/null
                        log_info "Secret ${EXTMODEL_SECRET} created/updated (bbr-managed label applied)"
                    fi
                fi

                if [ "$IS_35_PLUS" = true ]; then
                    log_step "Applying ExternalProvider + ExternalModel CRs (3.5+)..."
                    run_cmd oc apply -k "${PROVIDER_DIR}/model/"
                else
                    log_step "Applying ExternalModel CR (3.4)..."
                    run_cmd oc apply -f "${PROVIDER_DIR}/model/external-model-34.yaml"
                fi

                log_step "Applying MaaS governance (MaaSModelRef, AuthPolicy, Subscription)..."
                run_cmd oc apply -k "${PROVIDER_DIR}/maas/"

                if [ "$DRY_RUN" = false ]; then
                    log_info "Waiting for MaaSModelRef phase=Ready..."
                    TIMEOUT=180
                    ELAPSED=0
                    while [ $ELAPSED -lt $TIMEOUT ]; do
                        MODELREF_PHASE=$(oc get maasmodelref "$EXTMODEL_NAME" -n "$EXTMODEL_NS" \
                            -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
                        [ "$MODELREF_PHASE" = "Ready" ] && break
                        sleep 5
                        ELAPSED=$((ELAPSED + 5))
                    done
                    if [ "${MODELREF_PHASE:-}" = "Ready" ]; then
                        log_info "MaaSModelRef: Ready"
                    else
                        log_warn "MaaSModelRef not Ready after ${TIMEOUT}s (phase: ${MODELREF_PHASE:-unknown})"
                    fi

                    MAAS_GW="https://${MAAS_HOSTNAME}"
                    OC_TOKEN=$(oc whoami -t 2>/dev/null || echo "")
                    if [ -n "$OC_TOKEN" ]; then
                        MODEL_READY=$(curl -sk "${MAAS_GW}/maas-api/v1/models" \
                            -H "Authorization: Bearer ${OC_TOKEN}" 2>/dev/null \
                            | grep -o "\"id\":\"${EXTMODEL_NAME}\"" || echo "")
                        if [ -n "$MODEL_READY" ]; then
                            log_info "Model ${EXTMODEL_NAME} visible in MaaS API (ready)"
                        else
                            log_warn "Model ${EXTMODEL_NAME} not yet visible in MaaS API"
                        fi

                        log_step "Testing ${EXTERNAL_MODEL_PROVIDER} inference through MaaS gateway..."
                        log_info "Creating ephemeral API key for testing..."
                        API_KEY_RESPONSE=$(curl -sk -X POST "${MAAS_GW}/maas-api/v1/api-keys" \
                            -H "Authorization: Bearer ${OC_TOKEN}" \
                            -H "Content-Type: application/json" \
                            -d "{\"name\": \"phase8-test\", \"subscription\": \"${EXTMODEL_SUBSCRIPTION}\", \"expiresIn\": \"1h\", \"ephemeral\": true}" 2>/dev/null || echo "")

                        TEST_API_KEY=$(echo "$API_KEY_RESPONSE" | grep -o '"key":"[^"]*"' | head -1 | cut -d'"' -f4)

                        if [ -n "$TEST_API_KEY" ]; then
                            log_info "Ephemeral API key created"

                            INFERENCE_RESPONSE=$(curl -sk -X POST \
                                "${MAAS_GW}/external-models/${EXTMODEL_NAME}/v1/chat/completions" \
                                -H "Authorization: Bearer ${TEST_API_KEY}" \
                                -H "Content-Type: application/json" \
                                -d "{\"model\": \"${EXTMODEL_TARGET_MODEL}\", \"messages\": [{\"role\": \"user\", \"content\": \"Say hello in exactly 3 words.\"}], \"max_tokens\": 20}" \
                                --max-time 30 2>/dev/null || echo "")

                            if echo "$INFERENCE_RESPONSE" | grep -q '"choices"'; then
                                REPLY_TEXT=$(echo "$INFERENCE_RESPONSE" | grep -o '"content":"[^"]*"' | head -1 | cut -d'"' -f4)
                                log_info "${EXTERNAL_MODEL_PROVIDER} inference SUCCESS: ${REPLY_TEXT}"
                            else
                                HTTP_CODE=$(curl -sk -o /dev/null -w '%{http_code}' -X POST \
                                    "${MAAS_GW}/external-models/${EXTMODEL_NAME}/v1/chat/completions" \
                                    -H "Authorization: Bearer ${TEST_API_KEY}" \
                                    -H "Content-Type: application/json" \
                                    -d "{\"model\": \"${EXTMODEL_TARGET_MODEL}\", \"messages\": [{\"role\": \"user\", \"content\": \"Hi\"}], \"max_tokens\": 5}" \
                                    --max-time 15 2>/dev/null || echo "000")
                                log_warn "${EXTERNAL_MODEL_PROVIDER} inference returned HTTP ${HTTP_CODE} - model is registered and governed but inference routing may need BBR ext-proc propagation"
                            fi

                            TEST_KEY_ID=$(echo "$API_KEY_RESPONSE" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
                            if [ -n "$TEST_KEY_ID" ]; then
                                curl -sk -X DELETE "${MAAS_GW}/maas-api/v1/api-keys/${TEST_KEY_ID}" \
                                    -H "Authorization: Bearer ${OC_TOKEN}" &>/dev/null || true
                            fi
                        else
                            log_warn "Could not create API key for testing (response: $(echo "$API_KEY_RESPONSE" | head -c 200))"
                        fi
                    else
                        log_warn "No OC token available - skipping API verification"
                    fi
                fi

                log_info "External models deployment complete (provider: ${EXTERNAL_MODEL_PROVIDER})"
            fi
        fi
    fi
fi

# =============================================================================
# Final Summary
# =============================================================================
echo ""
log_phase "" "Summary"

MAAS_URL="https://${MAAS_HOSTNAME}"

if [ "$DRY_RUN" = true ]; then
    log_info "MaaS API URL:  ${MAAS_URL}"
    log_info "Status:        DRY RUN  - no changes applied"
else
    # Gather final state
    RHOAI_VERSION=$(oc get csv -n redhat-ods-operator -l operators.coreos.com/rhods-operator.redhat-ods-operator= -o jsonpath='{.items[0].spec.version}' 2>/dev/null || echo "unknown")
    GW_STATUS=$(oc get gateway maas-default-gateway -n openshift-ingress \
        -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || echo "Unknown")
    API_READY=$(oc get deployment maas-api -n "$MAAS_API_NS" \
        -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    HEALTH=$(curl -sk --connect-timeout 10 --max-time 15 -o /dev/null -w '%{http_code}' "${MAAS_URL}/maas-api/health" 2>/dev/null) || true
    [ -z "$HEALTH" ] && HEALTH="000"
    if [ "$HEALTH" = "000" ] && [ "$DISCONNECTED" = true ]; then
        GW_NODEPORT=$(oc get svc maas-default-gateway-openshift-default -n openshift-ingress \
            -o jsonpath='{.spec.ports[?(@.port==443)].nodePort}' 2>/dev/null || echo "")
        NODE_INT_IP=$(oc get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "")
        if [ -n "$GW_NODEPORT" ] && [ -n "$NODE_INT_IP" ]; then
            HEALTH=$(curl -sk --connect-timeout 10 --max-time 15 -o /dev/null -w '%{http_code}' \
                --resolve "${MAAS_HOSTNAME}:${GW_NODEPORT}:${NODE_INT_IP}" \
                "https://${MAAS_HOSTNAME}:${GW_NODEPORT}/maas-api/health" 2>/dev/null) || true
            [ -z "$HEALTH" ] && HEALTH="000"
            HEALTH="${HEALTH} (NodePort)"
        fi
    fi

    log_info "RHOAI version: ${RHOAI_VERSION}"
    log_info "MaaS API URL:  ${MAAS_URL}"
    log_info "Gateway:       Programmed=${GW_STATUS}"
    log_info "maas-api:      ${API_READY} replica(s)"
    log_info "Health:        HTTP ${HEALTH}"

    if [ "$SKIP_MODELS" = false ] && [ "$HAS_MODELS" = true ] || oc get llminferenceservice -n llm &>/dev/null 2>&1; then
        log_info "Models (local):"
        oc get llminferenceservice -n llm --no-headers 2>/dev/null | while read -r line; do
            log_info "  $line"
        done
    fi

    if oc get externalmodel -n external-models &>/dev/null 2>&1; then
        log_info "Models (external):"
        oc get externalmodel -n external-models --no-headers 2>/dev/null | while read -r line; do
            log_info "  $line"
        done
    fi

    echo ""
    log_info "Next steps:"
    [ "$SKIP_MODELS" = true ] && log_info "  Deploy models:      ./scripts/deploy-model.sh --model auto"
    [ "$SKIP_VERIFY" = true ] && log_info "  Run verification:   ./scripts/verify-maas.sh"
    [ "$WITH_OBSERVABILITY" = false ] && log_info "  Add observability:  $0 --from-phase 7 --with-observability"
    if [ "$DISCONNECTED" = true ]; then
        log_info "  (Phase 8 external models skipped - not available in disconnected mode)"
    elif [ "$WITH_EXTERNAL_MODELS" = false ]; then
        log_info "  Add external models: $0 --from-phase 8 --with-external-models --external-model-provider openai --external-model-api-key <KEY>"
    fi
    log_info "  RHOAI Dashboard:    https://$(oc get route rhods-dashboard -n redhat-ods-applications -o jsonpath='{.spec.host}' 2>/dev/null || echo '<dashboard-route>')"
fi

echo ""
log_info "Done."
