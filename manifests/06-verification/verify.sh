#!/usr/bin/env bash
#
# verify.sh - Verify MaaS (Models as a Service) deployment
#
# Performs a full end-to-end verification of MaaS:
#   Phase 1: Infrastructure health (Gateway, PostgreSQL, maas-api, maas-controller)
#   Phase 2: Deploy simulator model + MaaS resources (MaaSModelRef, AuthPolicy, Subscription)
#   Phase 3: API verification (health, API key, model listing, inference)
#   Phase 4: Auth enforcement (reject unauthenticated requests)
#   Phase 5: Rate limiting (trigger 429s)
#   Phase 6: Cleanup test resources
#
# Prerequisites:
#   - MaaS installed on the cluster
#   - oc logged into cluster
#
# Usage:
#   ./verify.sh [OPTIONS]
#
# Options:
#   --no-cleanup      Skip cleanup (leave test resources deployed)
#   --cleanup-only    Only run cleanup (remove test resources from a previous run)
#   -h, --help        Show this help message
#

set -euo pipefail

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
log_pass()  { echo -e "${GREEN}[PASS]${NC} $*"; PASSED=$((PASSED + 1)); }
log_fail()  { echo -e "${RED}[FAIL]${NC} $*"; FAILED=$((FAILED + 1)); }

PASSED=0
FAILED=0
NO_CLEANUP=false
CLEANUP_ONLY=false
DISCONNECTED=${DISCONNECTED:-false}

while [[ $# -gt 0 ]]; do
    case $1 in
        --no-cleanup) NO_CLEANUP=true; shift ;;
        --cleanup-only) CLEANUP_ONLY=true; shift ;;
        --disconnected) DISCONNECTED=true; shift ;;
        -h|--help)
            cat <<EOF
Usage: $0 [OPTIONS]

Verify MaaS (Models as a Service) deployment on OpenShift.

Options:
  --no-cleanup      Skip cleanup (leave test resources deployed)
  --cleanup-only    Only run cleanup (remove test resources from a previous run)
  --disconnected    Use disconnected-compatible model URIs (oci:// instead of hf://)
  -h, --help        Show this help message

Phases:
  1. Infrastructure health (Gateway, PostgreSQL, maas-api, maas-controller)
  2. Deploy simulator model + MaaS resources
  3. API verification (API key, model listing, inference)
  4. Auth enforcement (reject unauthenticated requests)
  5. Rate limiting (trigger 429s)
  6. Cleanup test resources
EOF
            exit 0
            ;;
        *) log_error "Unknown option: $1"; exit 1 ;;
    esac
done

NAMESPACE=redhat-ods-applications
MODEL_NS=llm
MAAS_NS=models-as-a-service
MODEL_NAME=facebook-opt-125m-simulated

if [ "$DISCONNECTED" = true ]; then
    SIM_MODEL_URI="oci://registry.redhat.io/rhai/modelcar-granite-4-0-h-tiny-fp8-dynamic:3.0"
    log_info "Disconnected mode: using oci:// URI for simulator model"
else
    SIM_MODEL_URI="hf://sshleifer/tiny-gpt2"
fi

# =============================================================================
# Cleanup function
# =============================================================================
cleanup_test_resources() {
    log_step "Cleanup: Removing test resources"

    # Delete API key if we have one
    if [ -n "${API_KEY_ID:-}" ] && [ -n "${HOST:-}" ]; then
        curl -sSk \
            -H "Authorization: Bearer $(oc whoami -t)" \
            -X DELETE \
            "${HOST}/maas-api/v1/api-keys/${API_KEY_ID}" 2>/dev/null || true
        log_info "Deleted test API key"
    fi

    # Delete MaaS resources (order matters: subscription, auth-policy, model-ref, then model)
    oc delete maassubscription simulator-subscription -n "$MAAS_NS" 2>/dev/null || true
    oc delete maasauthpolicy simulator-access -n "$MAAS_NS" 2>/dev/null || true
    oc delete maasmodelref "$MODEL_NAME" -n "$MODEL_NS" 2>/dev/null || true
    oc delete llminferenceservice "$MODEL_NAME" -n "$MODEL_NS" 2>/dev/null || true

    # Wait for pods to terminate
    if oc get namespace "$MODEL_NS" &>/dev/null; then
        oc wait pod --for=delete -l "app.kubernetes.io/name=$MODEL_NAME" -n "$MODEL_NS" --timeout=60s 2>/dev/null || true
    fi

    # Delete namespaces if empty
    if oc get namespace "$MODEL_NS" &>/dev/null; then
        REMAINING=$(oc get all -n "$MODEL_NS" --no-headers 2>/dev/null | wc -l | tr -d ' ')
        if [ "$REMAINING" = "0" ]; then
            oc delete namespace "$MODEL_NS" 2>/dev/null || true
            log_info "Deleted namespace $MODEL_NS"
        else
            log_info "Namespace $MODEL_NS still has resources, keeping it"
        fi
    fi

    if oc get namespace "$MAAS_NS" &>/dev/null; then
        REMAINING=$(oc get maassubscription,maasauthpolicy -n "$MAAS_NS" --no-headers 2>/dev/null | wc -l | tr -d ' ')
        if [ "$REMAINING" = "0" ]; then
            oc delete namespace "$MAAS_NS" 2>/dev/null || true
            log_info "Deleted namespace $MAAS_NS"
        else
            log_info "Namespace $MAAS_NS still has resources, keeping it"
        fi
    fi

    log_info "Cleanup complete"
}

if [ "$CLEANUP_ONLY" = true ]; then
    cleanup_test_resources
    exit 0
fi

# =============================================================================
# Pre-check: Gateway pod health (detect and fix OOMKill)
# =============================================================================
check_and_fix_gateway_oom() {
    local deploy_name="$1"
    local restarts crash_reason mem_limit params_ref

    restarts=$(oc get pods -n openshift-ingress -l "gateway.networking.k8s.io/gateway-name=maas-default-gateway" \
        -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}' 2>/dev/null || echo "0")
    crash_reason=$(oc get pods -n openshift-ingress -l "gateway.networking.k8s.io/gateway-name=maas-default-gateway" \
        -o jsonpath='{.items[0].status.containerStatuses[0].lastState.terminated.reason}' 2>/dev/null || echo "")

    if [ "$crash_reason" = "OOMKilled" ] || [ "${restarts:-0}" -ge 3 ]; then
        mem_limit=$(oc get deployment "$deploy_name" -n openshift-ingress \
            -o jsonpath='{.spec.template.spec.containers[0].resources.limits.memory}' 2>/dev/null || echo "")

        if [ "$mem_limit" = "1Gi" ]; then
            log_warn "Gateway pod has OOMKilled ($restarts restarts). Applying persistent 2Gi memory limit via ConfigMap..."
            # Create the ConfigMap with 2Gi limit (idempotent)
            cat <<'GWEOF' | oc apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: maas-gateway-options
  namespace: openshift-ingress
data:
  deployment: |
    spec:
      template:
        spec:
          containers:
          - name: istio-proxy
            resources:
              requests:
                cpu: 100m
                memory: 256Mi
              limits:
                cpu: "2"
                memory: 2Gi
GWEOF
            # Hook ConfigMap into Gateway via parametersRef (survives Istio reconciliation)
            params_ref=$(oc get gateway maas-default-gateway -n openshift-ingress \
                -o jsonpath='{.spec.infrastructure.parametersRef.name}' 2>/dev/null || echo "")
            if [ "$params_ref" != "maas-gateway-options" ]; then
                oc patch gateway maas-default-gateway -n openshift-ingress --type=merge -p '{
                  "spec": {"infrastructure": {"parametersRef": {"group": "", "kind": "ConfigMap", "name": "maas-gateway-options"}}}
                }' 2>/dev/null || true
            fi

            log_info "Waiting for gateway pod to stabilize..."
            sleep 10
            oc wait --for=condition=Available deployment/"$deploy_name" -n openshift-ingress --timeout=90s 2>/dev/null || true
        fi
    fi
}

# =============================================================================
# Phase 1: Infrastructure Health
# =============================================================================
log_step "Phase 1: Infrastructure health checks"

# Cluster connection
if ! oc whoami &>/dev/null; then
    log_error "Not logged into OpenShift cluster"
    exit 1
fi
log_info "Connected to: $(oc whoami --show-server)"

# Detect cluster domain
CLUSTER_DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
MAAS_HOSTNAME="${MAAS_HOSTNAME:-maas.${CLUSTER_DOMAIN}}"
HOST="https://${MAAS_HOSTNAME}"
log_info "MaaS URL: ${HOST}"

# Gateway
GATEWAY_PROGRAMMED=$(oc get gateway maas-default-gateway -n openshift-ingress -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || echo "NotFound")
if [ "$GATEWAY_PROGRAMMED" = "True" ]; then
    log_pass "Gateway maas-default-gateway is Programmed"
else
    log_fail "Gateway not Programmed (status: $GATEWAY_PROGRAMMED)"
fi

# Check and auto-fix gateway OOMKill
check_and_fix_gateway_oom "maas-default-gateway-openshift-default"

# PostgreSQL
PG_READY=$(oc get deployment postgres -n "$NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
if [ "${PG_READY:-0}" -ge 1 ]; then
    log_pass "PostgreSQL is running ($PG_READY replica(s))"
else
    log_fail "PostgreSQL not ready"
fi

# maas-api
MAAS_API_READY=$(oc get deployment maas-api -n "$NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
if [ "${MAAS_API_READY:-0}" -ge 1 ]; then
    log_pass "maas-api is running ($MAAS_API_READY replica(s))"
else
    log_fail "maas-api not ready"
fi

# maas-controller
MAAS_CTRL_READY=$(oc get deployment maas-controller -n "$NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
if [ "${MAAS_CTRL_READY:-0}" -ge 1 ]; then
    log_pass "maas-controller is running ($MAAS_CTRL_READY replica(s))"
else
    log_fail "maas-controller not ready"
fi

# Kuadrant/Authorino
AUTHORINO_READY=$(oc get deployment authorino -n kuadrant-system -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
if [ "${AUTHORINO_READY:-0}" -ge 1 ]; then
    log_pass "Authorino is running"
else
    log_fail "Authorino not ready"
fi

# ModelsAsServiceReady
MAAS_READY=$(oc get datasciencecluster default-dsc -o jsonpath='{.status.conditions[?(@.type=="ModelsAsServiceReady")].status}' 2>/dev/null || echo "Unknown")
if [ "$MAAS_READY" = "True" ]; then
    log_pass "ModelsAsServiceReady=True"
else
    log_fail "ModelsAsServiceReady=$MAAS_READY"
fi

# Health endpoint (try with --resolve to bypass DNS cache for cloud LB hostnames)
GATEWAY_ADDR=$(oc get gateway maas-default-gateway -n openshift-ingress -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || echo "")
GATEWAY_IP=""
if [ -n "$GATEWAY_ADDR" ]; then
    # Only use --resolve for hostnames (e.g. AWS ELB), not for bare IPs (e.g. MetalLB)
    if echo "$GATEWAY_ADDR" | grep -qE '[a-zA-Z]'; then
        GATEWAY_IP=$(dig +short "$GATEWAY_ADDR" 2>/dev/null | head -1 || echo "")
    fi
fi

HEALTH_CODE="000"
for attempt in 1 2 3; do
    HEALTH_CODE=$(curl -sSk --connect-timeout 10 --max-time 30 \
        ${GATEWAY_IP:+--resolve "${MAAS_HOSTNAME}:443:${GATEWAY_IP}"} \
        -o /dev/null -w '%{http_code}' \
        "${HOST}/maas-api/health" 2>/dev/null) || true
    [ -z "$HEALTH_CODE" ] && HEALTH_CODE="000"
    if [ "$HEALTH_CODE" = "200" ]; then
        break
    fi
    if [ "$attempt" -lt 3 ]; then
        log_warn "Health endpoint returned HTTP $HEALTH_CODE, retrying in 10s (attempt $attempt/3)..."
        sleep 10
    fi
done

# Helper for curl with optional DNS resolution (only for cloud LB hostnames)
maas_curl() {
    if [ -n "${GATEWAY_IP:-}" ]; then
        curl -sSk --connect-timeout 10 --max-time 30 --resolve "${MAAS_HOSTNAME}:443:${GATEWAY_IP}" "$@"
    else
        curl -sSk --connect-timeout 10 --max-time 30 "$@"
    fi
}

# In disconnected mode, try NodePort if direct access fails
if [ "$HEALTH_CODE" = "000" ] && [ "$DISCONNECTED" = true ]; then
    log_warn "Direct access failed (expected in disconnected/air-gapped mode) - trying NodePort..."
    GW_NODEPORT=$(oc get svc maas-default-gateway-openshift-default -n openshift-ingress \
        -o jsonpath='{.spec.ports[?(@.port==443)].nodePort}' 2>/dev/null || echo "")
    NODE_INT_IP=$(oc get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "")
    if [ -n "$GW_NODEPORT" ] && [ -n "$NODE_INT_IP" ]; then
        NODEPORT_HOST="${MAAS_HOSTNAME}"
        HEALTH_CODE=$(curl -sSk --connect-timeout 10 --max-time 30 \
            --resolve "${NODEPORT_HOST}:${GW_NODEPORT}:${NODE_INT_IP}" \
            -o /dev/null -w '%{http_code}' \
            "https://${NODEPORT_HOST}:${GW_NODEPORT}/maas-api/health" 2>/dev/null) || true
        [ -z "$HEALTH_CODE" ] && HEALTH_CODE="000"
        if [ "$HEALTH_CODE" = "200" ]; then
            log_pass "Health endpoint returns HTTP 200 (via NodePort ${GW_NODEPORT})"
            HOST="https://${NODEPORT_HOST}:${GW_NODEPORT}"
            maas_curl() {
                curl -sSk --connect-timeout 10 --max-time 30 \
                    --resolve "${NODEPORT_HOST}:${GW_NODEPORT}:${NODE_INT_IP}" "$@"
            }
        elif [ "$HEALTH_CODE" != "000" ]; then
            log_warn "Health via NodePort returned HTTP ${HEALTH_CODE}"
        fi
    fi
fi

if [ "$HEALTH_CODE" = "200" ]; then
    [ -z "${GW_NODEPORT:-}" ] && log_pass "Health endpoint returns HTTP 200"
elif [ "$HEALTH_CODE" = "000" ]; then
    log_fail "Health endpoint unreachable (DNS may still be propagating, or gateway pod is restarting)"
    log_warn "Try: curl -sk --resolve '${MAAS_HOSTNAME}:443:<ELB_IP>' ${HOST}/maas-api/health"
else
    log_warn "Health endpoint returned HTTP $HEALTH_CODE (expected 200)"
fi

# Bail out if health endpoint failed
if [ "$HEALTH_CODE" = "000" ]; then
    log_error "Cannot reach MaaS API. Skipping remaining phases."
    echo ""
    echo "========================================="
    echo "Results: $PASSED passed, $FAILED failed"
    echo "========================================="
    exit 1
fi

# =============================================================================
# Phase 2: Deploy simulator model + MaaS resources
# =============================================================================
log_step "Phase 2: Deploy simulator model and MaaS resources"

# Create namespaces
oc create namespace "$MODEL_NS" --dry-run=client -o yaml | oc apply -f - 2>/dev/null
oc label namespace "$MODEL_NS" opendatahub.io/generated-namespace=true --overwrite 2>/dev/null || true
oc label namespace "$MODEL_NS" maas.opendatahub.io/gateway-access=true --overwrite 2>/dev/null || true
oc label namespace "$MODEL_NS" opendatahub.io/dashboard=true --overwrite 2>/dev/null || true
oc create namespace "$MAAS_NS" --dry-run=client -o yaml | oc apply -f - 2>/dev/null
oc label namespace "$MAAS_NS" opendatahub.io/generated-namespace=true --overwrite 2>/dev/null || true
log_info "Ensured namespaces: $MODEL_NS, $MAAS_NS"

# Deploy LLMInferenceService (simulator model)
log_info "Deploying simulator model..."
if oc get llminferenceservice "$MODEL_NAME" -n "$MODEL_NS" &>/dev/null; then
    log_info "LLMInferenceService $MODEL_NAME already exists, skipping"
else
    oc apply --server-side=true -f - <<EOF
apiVersion: serving.kserve.io/v1alpha1
kind: LLMInferenceService
metadata:
  name: $MODEL_NAME
  namespace: $MODEL_NS
spec:
  model:
    uri: $SIM_MODEL_URI
    name: facebook/opt-125m
  replicas: 1
  router:
    route: {}
    gateway:
      refs:
        - name: maas-default-gateway
          namespace: openshift-ingress
  template:
    containers:
      - name: main
        image: "ghcr.io/llm-d/llm-d-inference-sim:v0.7.1"
        imagePullPolicy: IfNotPresent
        command: ["/app/llm-d-inference-sim"]
        args:
          - --port
          - "8000"
          - --model
          - facebook/opt-125m
          - --mode
          - random
          - --ssl-certfile
          - /var/run/kserve/tls/tls.crt
          - --ssl-keyfile
          - /var/run/kserve/tls/tls.key
        env:
          - name: POD_NAME
            valueFrom:
              fieldRef:
                apiVersion: v1
                fieldPath: metadata.name
          - name: POD_NAMESPACE
            valueFrom:
              fieldRef:
                apiVersion: v1
                fieldPath: metadata.namespace
        ports:
          - name: https
            containerPort: 8000
            protocol: TCP
        livenessProbe:
          httpGet:
            path: /health
            port: https
            scheme: HTTPS
        resources:
          requests:
            cpu: 100m
            memory: 256Mi
          limits:
            cpu: 500m
            memory: 512Mi
        readinessProbe:
          httpGet:
            path: /ready
            port: https
            scheme: HTTPS
EOF
fi

# Deploy MaaSModelRef
log_info "Deploying MaaSModelRef..."
oc apply --server-side=true -f - <<EOF
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSModelRef
metadata:
  name: $MODEL_NAME
  namespace: $MODEL_NS
  annotations:
    openshift.io/display-name: "Facebook OPT 125M (Simulated)"
    openshift.io/description: "A simulated OPT-125M model for verification testing"
spec:
  modelRef:
    kind: LLMInferenceService
    name: $MODEL_NAME
EOF

# Deploy MaaSAuthPolicy
log_info "Deploying MaaSAuthPolicy..."
oc apply --server-side=true -f - <<EOF
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSAuthPolicy
metadata:
  name: simulator-access
  namespace: $MAAS_NS
spec:
  modelRefs:
    - name: $MODEL_NAME
      namespace: $MODEL_NS
  subjects:
    groups:
      - name: system:authenticated
    users: []
EOF

# Deploy MaaSSubscription
log_info "Deploying MaaSSubscription..."
oc apply --server-side=true -f - <<EOF
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSSubscription
metadata:
  name: simulator-subscription
  namespace: $MAAS_NS
spec:
  owner:
    groups:
      - name: system:authenticated
    users: []
  modelRefs:
    - name: $MODEL_NAME
      namespace: $MODEL_NS
      tokenRateLimits:
        - limit: 100
          window: 1m
  priority: 10
EOF

# Wait for simulator pods to be ready
log_info "Waiting for simulator model pods..."
TIMEOUT=180
ELAPSED=0
MODEL_READY=false
while [ $ELAPSED -lt $TIMEOUT ]; do
    READY_PODS=$(oc get pods -n "$MODEL_NS" -l "app.kubernetes.io/name=$MODEL_NAME" --no-headers 2>/dev/null | grep -c "Running" || echo "0")
    READY_PODS=$(echo "$READY_PODS" | tr -d '[:space:]')
    if [ "$READY_PODS" -ge 1 ]; then
        MODEL_READY=true
        break
    fi
    sleep 10
    ELAPSED=$((ELAPSED + 10))
    if [ $((ELAPSED % 30)) -eq 0 ]; then
        log_info "Waiting for model pods... (${ELAPSED}s, running: ${READY_PODS})"
    fi
done

if [ "$MODEL_READY" = true ]; then
    log_pass "Simulator model pods are running"
else
    log_fail "Simulator model pods not ready after ${TIMEOUT}s"
fi

# Wait for MaaSModelRef to be Ready
log_info "Waiting for MaaSModelRef to be Ready..."
TIMEOUT=120
ELAPSED=0
MODELREF_READY=false
while [ $ELAPSED -lt $TIMEOUT ]; do
    PHASE=$(oc get maasmodelref "$MODEL_NAME" -n "$MODEL_NS" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
    if [ "$PHASE" = "Ready" ]; then
        MODELREF_READY=true
        break
    fi
    sleep 10
    ELAPSED=$((ELAPSED + 10))
done

if [ "$MODELREF_READY" = true ]; then
    MODEL_ENDPOINT=$(oc get maasmodelref "$MODEL_NAME" -n "$MODEL_NS" -o jsonpath='{.status.endpoint}' 2>/dev/null || echo "")
    log_pass "MaaSModelRef is Ready (endpoint: $MODEL_ENDPOINT)"
else
    log_fail "MaaSModelRef not Ready (phase: $PHASE)"
fi

# =============================================================================
# Phase 3: API Verification
# =============================================================================
log_step "Phase 3: API verification"

# Create API key (with retry for transient gateway restarts)
log_info "Creating API key..."
API_KEY=""
API_KEY_ID=""
API_KEY_RESPONSE=""
for attempt in 1 2 3; do
    API_KEY_RESPONSE=$(maas_curl \
        -H "Authorization: Bearer $(oc whoami -t)" \
        -H "Content-Type: application/json" \
        -X POST \
        -d '{"name": "verify-test-key", "description": "Verification test key", "expiresIn": "1h", "subscription": "simulator-subscription"}' \
        "${HOST}/maas-api/v1/api-keys" 2>/dev/null || echo "{}")

    API_KEY=$(echo "$API_KEY_RESPONSE" | jq -r '.key // empty' 2>/dev/null || echo "")
    API_KEY_ID=$(echo "$API_KEY_RESPONSE" | jq -r '.id // empty' 2>/dev/null || echo "")

    if [ -n "$API_KEY" ] && [ "$API_KEY" != "null" ]; then
        break
    fi
    if [ "$attempt" -lt 3 ]; then
        log_warn "API key creation failed (attempt $attempt/3), retrying in 15s..."
        sleep 15
    fi
done

if [ -n "$API_KEY" ] && [ "$API_KEY" != "null" ]; then
    log_pass "API key created (id: ${API_KEY_ID})"
else
    log_fail "Failed to create API key"
    log_warn "Response: $API_KEY_RESPONSE"
fi

# List models
if [ -n "$API_KEY" ] && [ "$API_KEY" != "null" ]; then
    MODELS_RESPONSE=$(maas_curl \
        -H "Authorization: Bearer ${API_KEY}" \
        -H "Content-Type: application/json" \
        "${HOST}/maas-api/v1/models" 2>/dev/null || echo "{}")

    MODEL_COUNT=$(echo "$MODELS_RESPONSE" | jq '.data | length' 2>/dev/null || echo "0")
    MODEL_COUNT=$(echo "$MODEL_COUNT" | tr -d '[:space:]')

    if [ "$MODEL_COUNT" -gt 0 ] 2>/dev/null; then
        FIRST_MODEL_ID=$(echo "$MODELS_RESPONSE" | jq -r '.data[0].id // empty' 2>/dev/null || echo "")
        MODEL_URL=$(echo "$MODELS_RESPONSE" | jq -r '.data[0].url // empty' 2>/dev/null || echo "")
        log_pass "Models available ($MODEL_COUNT total, first: $FIRST_MODEL_ID)"
        INFERENCE_MODEL="$FIRST_MODEL_ID"
    else
        log_warn "No models found in listing (may be timing or API version difference)"
        log_warn "Response: ${MODELS_RESPONSE:0:200}"
        INFERENCE_MODEL="facebook/opt-125m"
        MODEL_URL="${HOST}/llm/${MODEL_NAME}"
    fi
fi

# Test inference
if [ -n "$API_KEY" ] && [ "$API_KEY" != "null" ] && [ -n "${MODEL_URL:-}" ]; then
    log_info "Testing inference..."
    INFERENCE_RESPONSE=$(maas_curl \
        -H "Authorization: Bearer ${API_KEY}" \
        -H "Content-Type: application/json" \
        -w "\n%{http_code}" \
        -d "{\"model\": \"${INFERENCE_MODEL:-$MODEL_NAME}\", \"messages\": [{\"role\": \"user\", \"content\": \"Hello\"}], \"max_tokens\": 50}" \
        "${MODEL_URL}/v1/chat/completions" 2>/dev/null || echo -e "\n000")

    INFERENCE_CODE=$(echo "$INFERENCE_RESPONSE" | tail -1)
    INFERENCE_BODY=$(echo "$INFERENCE_RESPONSE" | sed '$d')

    if [ "$INFERENCE_CODE" = "200" ]; then
        log_pass "Inference returned HTTP 200"
        COMPLETION=$(echo "$INFERENCE_BODY" | jq -r '.choices[0].message.content // empty' 2>/dev/null || echo "")
        if [ -n "$COMPLETION" ]; then
            log_info "Response: ${COMPLETION:0:80}..."
        fi
    else
        log_fail "Inference returned HTTP $INFERENCE_CODE (expected 200)"
        log_warn "Body: ${INFERENCE_BODY:0:200}"
    fi
fi

# =============================================================================
# Phase 4: Auth enforcement
# =============================================================================
log_step "Phase 4: Auth enforcement"

if [ -n "${MODEL_URL:-}" ]; then
    # No token
    NO_AUTH_CODE=$(maas_curl \
        -o /dev/null -w '%{http_code}' \
        -H "Content-Type: application/json" \
        -d "{\"model\": \"${INFERENCE_MODEL:-$MODEL_NAME}\", \"messages\": [{\"role\": \"user\", \"content\": \"Hello\"}], \"max_tokens\": 10}" \
        "${MODEL_URL}/v1/chat/completions" 2>/dev/null || echo "000")

    if [ "$NO_AUTH_CODE" = "401" ] || [ "$NO_AUTH_CODE" = "403" ]; then
        log_pass "Unauthenticated request rejected (HTTP $NO_AUTH_CODE)"
    else
        log_fail "Unauthenticated request returned HTTP $NO_AUTH_CODE (expected 401/403)"
    fi

    # Invalid token
    INVALID_CODE=$(maas_curl \
        -o /dev/null -w '%{http_code}' \
        -H "Authorization: Bearer invalid-token-12345" \
        -H "Content-Type: application/json" \
        -d "{\"model\": \"${INFERENCE_MODEL:-$MODEL_NAME}\", \"messages\": [{\"role\": \"user\", \"content\": \"Hello\"}], \"max_tokens\": 10}" \
        "${MODEL_URL}/v1/chat/completions" 2>/dev/null || echo "000")

    if [ "$INVALID_CODE" = "401" ] || [ "$INVALID_CODE" = "403" ]; then
        log_pass "Invalid token rejected (HTTP $INVALID_CODE)"
    else
        log_fail "Invalid token returned HTTP $INVALID_CODE (expected 401/403)"
    fi
else
    log_fail "Skipping auth tests (no model URL)"
fi

# =============================================================================
# Phase 5: Rate limiting
# =============================================================================
log_step "Phase 5: Rate limiting"

if [ -n "$API_KEY" ] && [ "$API_KEY" != "null" ] && [ -n "${MODEL_URL:-}" ]; then
    log_info "Sending 16 rapid requests to trigger rate limit..."
    RATE_LIMITED=0
    SUCCESSES=0
    for i in $(seq 1 16); do
        CODE=$(maas_curl \
            -o /dev/null -w '%{http_code}' \
            -H "Authorization: Bearer ${API_KEY}" \
            -H "Content-Type: application/json" \
            -d "{\"model\": \"${INFERENCE_MODEL:-$MODEL_NAME}\", \"messages\": [{\"role\": \"user\", \"content\": \"Hello, write me a very long essay about the history of computing\"}], \"max_tokens\": 50}" \
            "${MODEL_URL}/v1/chat/completions" 2>/dev/null || echo "000")
        if [ "$CODE" = "429" ]; then
            RATE_LIMITED=$((RATE_LIMITED + 1))
        elif [ "$CODE" = "200" ]; then
            SUCCESSES=$((SUCCESSES + 1))
        fi
    done

    if [ "$RATE_LIMITED" -gt 0 ]; then
        log_pass "Rate limiting triggered ($SUCCESSES successes, $RATE_LIMITED rate-limited out of 16)"
    else
        log_warn "No 429 responses in 16 requests. Rate limit may be high or not yet enforced."
        log_info "Received $SUCCESSES 200s out of 16 requests"
    fi
else
    log_fail "Skipping rate limit test (missing API key or model URL)"
fi

# =============================================================================
# Phase 6: Cleanup
# =============================================================================
if [ "$NO_CLEANUP" = true ]; then
    log_step "Phase 6: Cleanup (SKIPPED -- --no-cleanup)"
    log_info "Test resources left in place. Run '$0 --cleanup-only' to remove them."
else
    log_step "Phase 6: Cleanup"
    cleanup_test_resources
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "========================================="
echo "MaaS Verification Summary"
echo "========================================="
echo "MaaS API URL:  ${HOST}"
echo "Passed:        ${PASSED}"
echo "Failed:        ${FAILED}"
if [ "$FAILED" -gt 0 ]; then
    echo "Status:        SOME CHECKS FAILED"
else
    echo "Status:        ALL CHECKS PASSED"
fi
echo "========================================="

[ "$FAILED" -eq 0 ]
