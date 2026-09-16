#!/usr/bin/env bash
#
# deploy-model.sh - Deploy a MaaS model on an RHOAI cluster
#
# Supports auto-detection of GPU capabilities to select the appropriate model:
#   - No GPU             -> simulator (CPU-only mock)
#   - GPU VRAM >= 22 GiB -> gpt-oss-20b (quantized; 24 GB-class cards - L4, L40S, A100 - report ~23 GiB)
#   - GPU VRAM >= 16 GiB -> gemma
#   - GPU VRAM <  16 GiB -> granite-tiny-gpu
#
# Usage:
#   ./scripts/deploy-model.sh [OPTIONS]
#
# Options:
#   --model <name>  Model to deploy: simulator, granite-tiny-gpu, gemma, gpt-oss-20b, qwen3-06b, auto (default: auto)
#   --dry-run       Preview without applying
#   -h, --help      Show this help message
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODELS_DIR="$SCRIPT_DIR/../manifests/05-maas-models"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_step()  { echo -e "${BLUE}[STEP]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

MODEL="auto"
DRY_RUN=false
DISCONNECTED=${DISCONNECTED:-false}

while [[ $# -gt 0 ]]; do
    case $1 in
        --model)
            MODEL="$2"
            shift 2
            ;;
        --dry-run) DRY_RUN=true; shift ;;
        --disconnected) DISCONNECTED=true; shift ;;
        -h|--help)
            cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --model <name>  Model to deploy (default: auto)
                  Available models:
                    simulator                CPU-only mock model (~256Mi RAM)
                    simulator-disconnected   CPU-only mock for air-gapped clusters (oci:// URI)
                    granite-tiny-gpu         Granite 4.0-h-tiny FP8 (1 GPU, 24Gi RAM)
                    gpt-oss-20b              OpenAI gpt-oss-20b (1 GPU, 60Gi RAM)
                    gemma                    Gemma 2 9B IT FP8 (1 GPU, 24Gi RAM)
                    qwen3-06b                Qwen3-0.6B CPU (no GPU, 16Gi RAM, HuggingFace)
                    auto                     Auto-detect based on GPU VRAM (default)
  --disconnected  Use disconnected-compatible variants (oci:// URIs)
  --dry-run       Preview without applying
  -h, --help      Show this help message

Auto-detection rules:
  - No GPU node             -> simulator (or simulator-disconnected with --disconnected)
  - GPU VRAM >= 22 GiB      -> gpt-oss-20b (quantized, fits 24 GB-class cards: L4, L40S, A100)
  - GPU VRAM >= 16 GiB      -> gemma
  - GPU VRAM <  16 GiB      -> granite-tiny-gpu
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

# =============================================================================
# Preflight
# =============================================================================
log_step "Preflight checks"

if ! oc whoami &>/dev/null; then
    log_error "Not logged into OpenShift cluster"
    exit 1
fi
log_info "Connected to: $(oc whoami --show-server)"

# =============================================================================
# Model selection
# =============================================================================
log_step "Model selection"

if [ "$MODEL" = "auto" ]; then
    log_info "Auto-detecting GPU capabilities..."

    # Check for GPU memory label on any node
    GPU_MEMORY=$(oc get nodes -o jsonpath='{.items[*].metadata.labels.nvidia\.com/gpu\.memory}' 2>/dev/null | tr ' ' '\n' | sort -rn | head -1)

    if [ -z "$GPU_MEMORY" ]; then
        if [ "$DISCONNECTED" = true ]; then
            log_info "No GPU nodes detected (disconnected mode), selecting simulator-disconnected"
            MODEL="simulator-disconnected"
        else
            log_info "No GPU nodes detected, selecting simulator"
            log_info "Hint: use --model qwen3-06b for real CPU inference (~16Gi RAM, downloads from HuggingFace)"
            MODEL="simulator"
        fi
    elif [ "$GPU_MEMORY" -ge 22528 ] 2>/dev/null; then
        log_info "GPU VRAM: ${GPU_MEMORY} MiB (>= 22528), selecting gpt-oss-20b (quantized, fits 24 GB-class GPUs)"
        MODEL="gpt-oss-20b"
    elif [ "$GPU_MEMORY" -ge 16384 ] 2>/dev/null; then
        log_info "GPU VRAM: ${GPU_MEMORY} MiB (>= 16384), selecting gemma"
        MODEL="gemma"
    else
        log_info "GPU VRAM: ${GPU_MEMORY} MiB (< 16384), selecting granite-tiny-gpu"
        MODEL="granite-tiny-gpu"
    fi
fi

# Validate selected model
VALID_MODELS="simulator simulator-disconnected granite-tiny-gpu gpt-oss-20b gemma qwen3-06b"
if ! echo "$VALID_MODELS" | grep -qw "$MODEL"; then
    log_error "Unknown model: $MODEL"
    log_error "Valid models: $VALID_MODELS"
    exit 1
fi

MODEL_DIR="$MODELS_DIR/$MODEL"
if [ ! -d "$MODEL_DIR" ]; then
    log_error "Model directory not found: $MODEL_DIR"
    exit 1
fi

log_info "Selected model: $MODEL"

# =============================================================================
# Prepare llm namespace
# =============================================================================
log_step "Preparing llm namespace"

if ! oc get namespace llm &>/dev/null; then
    run_cmd oc create namespace llm
fi
oc label namespace llm opendatahub.io/generated-namespace=true --overwrite 2>/dev/null || true
oc label namespace llm maas.opendatahub.io/gateway-access=true --overwrite 2>/dev/null || true
oc label namespace llm opendatahub.io/dashboard=true --overwrite 2>/dev/null || true
log_info "llm namespace ready with required labels"

# =============================================================================
# Deploy model
# =============================================================================
log_step "Deploying model: $MODEL"

log_info "Applying manifests from manifests/05-maas-models/$MODEL/..."
run_cmd oc apply -k "$MODEL_DIR/"
log_info "Model manifests applied"

if [ "$DRY_RUN" = true ]; then
    log_info "[DRY RUN] Skipping deployment wait"
    log_info "========================================="
    log_info "Model Deployment Summary (DRY RUN)"
    log_info "========================================="
    log_info "Model:     $MODEL"
    log_info "Directory: manifests/05-maas-models/$MODEL/"
    log_info "========================================="
    exit 0
fi

# =============================================================================
# Wait for model readiness
# =============================================================================
log_step "Waiting for model readiness"

# Wait for LLMInferenceService pods
log_info "Waiting for LLMInferenceService pods to be Running..."
TIMEOUT=600
ELAPSED=0
PODS_READY=false
while [ $ELAPSED -lt $TIMEOUT ]; do
    # Check if any pods exist for the model in the llm namespace
    POD_COUNT=$(oc get pods -n llm --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [ "$POD_COUNT" -gt 0 ]; then
        # NOTE: grep -v returns 1 when everything is Running - guard it, or
        # pipefail + set -e kills the script at the moment of success
        NOT_READY=$(oc get pods -n llm --no-headers 2>/dev/null | { grep -v "Running\|Completed" || true; } | wc -l | tr -d ' ')
        if [ "$NOT_READY" -eq 0 ]; then
            log_info "All pods in llm namespace are Running"
            PODS_READY=true
            break
        fi
    fi
    sleep 10
    ELAPSED=$((ELAPSED + 10))
    if [ $((ELAPSED % 60)) -eq 0 ]; then
        log_info "Still waiting for pods... (${ELAPSED}s elapsed)"
        oc get pods -n llm --no-headers 2>/dev/null | head -5 || true
    fi
done

if [ "$PODS_READY" = false ]; then
    log_warn "Pods did not all reach Running state within ${TIMEOUT}s"
    log_warn "Current pod status:"
    oc get pods -n llm --no-headers 2>/dev/null || true
fi

# Wait for MaaSModelRef phase=Ready. Watch THIS model's modelref by name -
# with several models deployed, .items[0] can be a different (older) model.
MODELREF_NAME=$(awk '/^  name:/{print $2; exit}' "$MODEL_DIR/maas/maas-model.yaml" 2>/dev/null || echo "")
log_info "Waiting for MaaSModelRef ${MODELREF_NAME:-<first>} to be Ready..."
TIMEOUT=300
ELAPSED=0
MODEL_READY=false
while [ $ELAPSED -lt $TIMEOUT ]; do
    if [ -n "$MODELREF_NAME" ]; then
        PHASE=$(oc get maasmodelref "$MODELREF_NAME" -n llm -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    else
        PHASE=$(oc get maasmodelref -n llm -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")
    fi
    if [ "$PHASE" = "Ready" ]; then
        log_info "MaaSModelRef phase: Ready"
        MODEL_READY=true
        break
    fi
    sleep 10
    ELAPSED=$((ELAPSED + 10))
    if [ $((ELAPSED % 60)) -eq 0 ]; then
        log_info "Still waiting for MaaSModelRef... (${ELAPSED}s, phase: ${PHASE:-unknown})"
    fi
done

if [ "$MODEL_READY" = false ]; then
    log_warn "MaaSModelRef did not reach Ready phase within ${TIMEOUT}s (current: ${PHASE:-unknown})"
fi

log_info "========================================="
log_info "Model Deployment Summary"
log_info "========================================="
log_info "Model:          $MODEL"
log_info "Pods Ready:     $PODS_READY"
log_info "MaaSModelRef:   ${PHASE:-unknown}"
log_info "========================================="
log_info "Next steps:"
log_info "  - Verify MaaS: ./scripts/verify-maas.sh"
log_info "========================================="
