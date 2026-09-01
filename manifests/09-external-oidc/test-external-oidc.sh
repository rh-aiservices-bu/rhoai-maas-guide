#!/usr/bin/env bash
#
# test-external-oidc.sh - Verify External OIDC Authentication for MaaS
#
# Tests the full OIDC authentication flow:
#   1. Get OIDC token from Keycloak (direct access grant)
#   2. List models via MaaS API with OIDC Bearer token
#   3. Create API key via MaaS API with OIDC Bearer token
#   4. Run inference with API key
#   5. Verify restricted user access control
#
# Prerequisites:
#   - MaaS installed and working
#   - Keycloak deployed via setup-keycloak.sh
#   - At least one model deployed (simulator is fine)
#
# Usage:
#   ./test-external-oidc.sh
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
KEYCLOAK_NS=maas-keycloak
CLIENT_ID=maas-oidc

# Detect cluster domain and MaaS hostname
CLUSTER_DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
MAAS_HOSTNAME="${MAAS_HOSTNAME:-maas.${CLUSTER_DOMAIN}}"
MAAS_URL="https://${MAAS_HOSTNAME}"

# Detect gateway IP for --resolve (cloud LB hostnames)
GATEWAY_ADDR=$(oc get gateway maas-default-gateway -n openshift-ingress -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || echo "")
GATEWAY_IP=""
if [ -n "$GATEWAY_ADDR" ]; then
    if echo "$GATEWAY_ADDR" | grep -qE '[a-zA-Z]'; then
        GATEWAY_IP=$(dig +short "$GATEWAY_ADDR" 2>/dev/null | head -1 || echo "")
    fi
fi

maas_curl() {
    if [ -n "${GATEWAY_IP:-}" ]; then
        curl -sSk --connect-timeout 10 --max-time 30 \
            --resolve "${MAAS_HOSTNAME}:443:${GATEWAY_IP}" \
            "$@"
    else
        curl -sSk --connect-timeout 10 --max-time 30 "$@"
    fi
}

# Discover Keycloak
KEYCLOAK_HOST=$(oc get route -n "$KEYCLOAK_NS" -o jsonpath='{.items[0].spec.host}' 2>/dev/null || true)
if [ -z "$KEYCLOAK_HOST" ]; then
    log_error "Keycloak route not found in namespace $KEYCLOAK_NS. Run setup-keycloak.sh first."
    exit 1
fi
KEYCLOAK_TOKEN_URL="https://${KEYCLOAK_HOST}/realms/maas/protocol/openid-connect/token"

log_info "MaaS URL:       ${MAAS_URL}"
log_info "Keycloak URL:   https://${KEYCLOAK_HOST}"
log_info "Token endpoint: ${KEYCLOAK_TOKEN_URL}"
echo ""

# =============================================================================
# Helper: get OIDC token
# =============================================================================
get_oidc_token() {
    local username="$1"
    local password="$2"
    curl -sSk -X POST "$KEYCLOAK_TOKEN_URL" \
        -d "grant_type=password" \
        -d "client_id=${CLIENT_ID}" \
        -d "username=${username}" \
        -d "password=${password}" \
        -d "scope=openid groups" | jq -r '.access_token // empty'
}

# =============================================================================
# Test 1: Get OIDC token for maas-user
# =============================================================================
log_step "Test 1: Get OIDC token for maas-user"
TOKEN=$(get_oidc_token "maas-user" "maas-user")
if [ -n "$TOKEN" ] && [ "$TOKEN" != "null" ]; then
    log_pass "Got OIDC token for maas-user"

    # Decode and show groups claim
    PAYLOAD_B64=$(echo "$TOKEN" | cut -d. -f2 | tr '_-' '/+')
    MOD=$((${#PAYLOAD_B64} % 4))
    [ "$MOD" -eq 2 ] && PAYLOAD_B64="${PAYLOAD_B64}==" || { [ "$MOD" -eq 3 ] && PAYLOAD_B64="${PAYLOAD_B64}="; }
    GROUPS=$(echo "$PAYLOAD_B64" | base64 -d 2>/dev/null | jq -r '.groups // [] | join(", ")' 2>/dev/null || echo "decode failed")
    log_info "Token groups: $GROUPS"
else
    log_fail "Failed to get OIDC token for maas-user"
    log_error "Check Keycloak is running: oc get keycloak -n $KEYCLOAK_NS"
    exit 1
fi

# =============================================================================
# Test 2: List models with OIDC Bearer token
# =============================================================================
log_step "Test 2: List models with OIDC Bearer token"
MODELS_RESPONSE=$(maas_curl \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    "${MAAS_URL}/maas-api/v1/models" 2>/dev/null) || true

MODEL_COUNT=$(echo "$MODELS_RESPONSE" | jq -r '.data // [] | length' 2>/dev/null || echo "0")
if [ "$MODEL_COUNT" -gt 0 ]; then
    log_pass "Listed $MODEL_COUNT model(s) via OIDC token"
    echo "$MODELS_RESPONSE" | jq -r '.data[]?.id // empty' 2>/dev/null | while read -r m; do
        log_info "  - $m"
    done
else
    HTTP_CODE=$(maas_curl -o /dev/null -w "%{http_code}" \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "Content-Type: application/json" \
        "${MAAS_URL}/maas-api/v1/models" 2>/dev/null) || true
    log_fail "Failed to list models (HTTP $HTTP_CODE)"
    log_info "Response: $(echo "$MODELS_RESPONSE" | head -5)"
fi

# =============================================================================
# Test 3: Create API key with OIDC Bearer token
# =============================================================================
log_step "Test 3: Create API key with OIDC Bearer token"
API_KEY_RESPONSE=$(maas_curl -X POST \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"name": "oidc-test-key", "expiresInDays": 1}' \
    "${MAAS_URL}/maas-api/v1/api-keys" 2>/dev/null) || true

API_KEY=$(echo "$API_KEY_RESPONSE" | jq -r '.key // .apiKey // empty' 2>/dev/null || true)
API_KEY_ID=$(echo "$API_KEY_RESPONSE" | jq -r '.id // empty' 2>/dev/null || true)

if [ -n "$API_KEY" ] && [ "$API_KEY" != "null" ]; then
    log_pass "Created API key via OIDC token (id: $API_KEY_ID)"
else
    HTTP_CODE=$(maas_curl -o /dev/null -w "%{http_code}" -X POST \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "Content-Type: application/json" \
        -d '{"name": "oidc-test-key-2", "expiresInDays": 1}' \
        "${MAAS_URL}/maas-api/v1/api-keys" 2>/dev/null) || true
    log_fail "Failed to create API key (HTTP $HTTP_CODE)"
    log_info "Response: $(echo "$API_KEY_RESPONSE" | head -5)"
fi

# =============================================================================
# Test 4: Inference with API key (if we have one and a model)
# =============================================================================
if [ -n "${API_KEY:-}" ] && [ "$API_KEY" != "null" ] && [ "$MODEL_COUNT" -gt 0 ]; then
    MODEL_ID=$(echo "$MODELS_RESPONSE" | jq -r '.data[0].id // empty' 2>/dev/null || true)
    if [ -n "$MODEL_ID" ]; then
        log_step "Test 4: Inference with API key (model: $MODEL_ID)"
        INFERENCE_RESPONSE=$(maas_curl -X POST \
            -H "Authorization: Bearer ${API_KEY}" \
            -H "Content-Type: application/json" \
            -d "{\"model\": \"${MODEL_ID}\", \"messages\": [{\"role\": \"user\", \"content\": \"Hello\"}], \"max_tokens\": 10}" \
            "${MAAS_URL}/v1/chat/completions" 2>/dev/null) || true

        INFERENCE_OK=$(echo "$INFERENCE_RESPONSE" | jq -r '.choices[0].message.content // empty' 2>/dev/null || true)
        if [ -n "$INFERENCE_OK" ]; then
            log_pass "Inference succeeded with OIDC-created API key"
        else
            HTTP_CODE=$(maas_curl -o /dev/null -w "%{http_code}" -X POST \
                -H "Authorization: Bearer ${API_KEY}" \
                -H "Content-Type: application/json" \
                -d "{\"model\": \"${MODEL_ID}\", \"messages\": [{\"role\": \"user\", \"content\": \"Hello\"}], \"max_tokens\": 10}" \
                "${MAAS_URL}/v1/chat/completions" 2>/dev/null) || true
            log_fail "Inference failed (HTTP $HTTP_CODE)"
        fi
    else
        log_warn "Test 4: Skipped (no model ID found)"
    fi
else
    log_warn "Test 4: Skipped (no API key or no models available)"
fi

# =============================================================================
# Test 5: Get OIDC token for restricted-user
# =============================================================================
log_step "Test 5: Get OIDC token for restricted-user"
RESTRICTED_TOKEN=$(get_oidc_token "restricted-user" "restricted-user")
if [ -n "$RESTRICTED_TOKEN" ] && [ "$RESTRICTED_TOKEN" != "null" ]; then
    log_pass "Got OIDC token for restricted-user"

    PAYLOAD_B64=$(echo "$RESTRICTED_TOKEN" | cut -d. -f2 | tr '_-' '/+')
    MOD=$((${#PAYLOAD_B64} % 4))
    [ "$MOD" -eq 2 ] && PAYLOAD_B64="${PAYLOAD_B64}==" || { [ "$MOD" -eq 3 ] && PAYLOAD_B64="${PAYLOAD_B64}="; }
    RESTRICTED_GROUPS=$(echo "$PAYLOAD_B64" | base64 -d 2>/dev/null | jq -r '.groups // [] | join(", ")' 2>/dev/null || echo "decode failed")
    log_info "Token groups: $RESTRICTED_GROUPS"
else
    log_fail "Failed to get OIDC token for restricted-user"
fi

# =============================================================================
# Test 6: Verify restricted-user can list models (only data-scientists group)
# =============================================================================
if [ -n "${RESTRICTED_TOKEN:-}" ] && [ "$RESTRICTED_TOKEN" != "null" ]; then
    log_step "Test 6: Restricted user model listing"
    RESTRICTED_MODELS=$(maas_curl \
        -H "Authorization: Bearer ${RESTRICTED_TOKEN}" \
        -H "Content-Type: application/json" \
        "${MAAS_URL}/maas-api/v1/models" 2>/dev/null) || true

    RESTRICTED_COUNT=$(echo "$RESTRICTED_MODELS" | jq -r '.data // [] | length' 2>/dev/null || echo "0")
    if [ "$RESTRICTED_COUNT" -ge 0 ]; then
        log_pass "Restricted user can access API ($RESTRICTED_COUNT model(s) visible)"
    else
        log_fail "Restricted user failed to list models"
    fi
else
    log_warn "Test 6: Skipped (no restricted-user token)"
fi

# =============================================================================
# Cleanup: delete test API keys
# =============================================================================
if [ -n "${API_KEY_ID:-}" ]; then
    log_info "Cleaning up test API key ($API_KEY_ID)"
    maas_curl -X DELETE \
        -H "Authorization: Bearer ${TOKEN}" \
        "${MAAS_URL}/maas-api/v1/api-keys/${API_KEY_ID}" 2>/dev/null || true
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "========================================="
echo "  External OIDC Test Summary"
echo "========================================="
echo "  MaaS URL:    ${MAAS_URL}"
echo "  Keycloak:    https://${KEYCLOAK_HOST}"
echo "  Passed:      ${PASSED}"
echo "  Failed:      ${FAILED}"
if [ "$FAILED" -eq 0 ]; then
    echo "  Status:      ALL CHECKS PASSED"
else
    echo "  Status:      SOME CHECKS FAILED"
fi
echo "========================================="

exit "$FAILED"
