#!/usr/bin/env bash
#
# setup-keycloak.sh - Deploy Keycloak for MaaS External OIDC Authentication
#
# Deploys Red Hat Build of Keycloak (RHBK) with a PostgreSQL database and
# imports a realm configured for MaaS group-based OIDC authentication.
#
# Prerequisites:
#   - oc logged into cluster
#   - MaaS installed and working (Phases 1-5)
#
# Usage:
#   ./setup-keycloak.sh [OPTIONS]
#
# Options:
#   --cleanup         Remove Keycloak and OIDC configuration
#   -h, --help        Show this help message
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

KEYCLOAK_NS=maas-keycloak
MAAS_NS=models-as-a-service

# Auto-detect RHOAI version
if oc get crd aitenants.maas.opendatahub.io &>/dev/null; then
    RHOAI_35=true
    AI_TENANTS_NS=ai-tenants
    log_info "Detected RHOAI 3.5+ (AITenant CRD found)"
else
    RHOAI_35=false
    AI_TENANTS_NS=""
    log_info "Detected RHOAI 3.4 (using Tenant CRD)"
fi

# Parse arguments
CLEANUP=false
while [[ $# -gt 0 ]]; do
    case $1 in
        --cleanup)    CLEANUP=true; shift ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's/^# *//'
            exit 0
            ;;
        *) log_error "Unknown option: $1"; exit 1 ;;
    esac
done

# =============================================================================
# Cleanup
# =============================================================================
if [ "$CLEANUP" = true ]; then
    log_step "Removing OIDC configuration from MaaS tenant"
    if [ "$RHOAI_35" = true ]; then
        oc patch aitenants.maas.opendatahub.io models-as-a-service -n "$AI_TENANTS_NS" \
            --type json \
            -p '[{"op": "remove", "path": "/spec/oidc"}]' 2>/dev/null || log_warn "OIDC config already removed or not present"
    else
        oc patch tenants.maas.opendatahub.io default-tenant -n "$MAAS_NS" \
            --type json \
            -p '[{"op": "remove", "path": "/spec/externalOIDC"}]' 2>/dev/null || log_warn "OIDC config already removed or not present"
    fi

    log_step "Removing OIDC subscriptions and auth policies"
    oc delete maassubscription oidc-data-scientists oidc-ml-engineers -n "$MAAS_NS" 2>/dev/null || true
    oc delete maasauthpolicy oidc-data-scientists-access oidc-ml-engineers-access -n "$MAAS_NS" 2>/dev/null || true

    log_step "Removing Keycloak namespace"
    oc delete namespace "$KEYCLOAK_NS" 2>/dev/null || true
    log_info "Cleanup complete"
    exit 0
fi

# =============================================================================
# Step 1: Create namespace
# =============================================================================
log_step "Step 1: Creating namespace $KEYCLOAK_NS"
oc create namespace "$KEYCLOAK_NS" --dry-run=client -o yaml | oc apply -f -

# =============================================================================
# Step 2: Deploy RHBK operator
# =============================================================================
log_step "Step 2: Deploying Red Hat Build of Keycloak operator"
oc apply -k "$SCRIPT_DIR/keycloak/operator/"

log_info "Waiting for RHBK operator CSV to succeed..."
for i in $(seq 1 60); do
    CSV=$(oc get csv -n "$KEYCLOAK_NS" -o name 2>/dev/null | grep rhbk || true)
    if [ -n "$CSV" ]; then
        PHASE=$(oc get "$CSV" -n "$KEYCLOAK_NS" -o jsonpath='{.status.phase}' 2>/dev/null || true)
        if [ "$PHASE" = "Succeeded" ]; then
            log_info "RHBK operator installed: $CSV"
            break
        fi
    fi
    if [ "$i" -eq 60 ]; then
        log_error "Timed out waiting for RHBK operator"
        exit 1
    fi
    sleep 5
done

# =============================================================================
# Step 3: Deploy Keycloak instance
# =============================================================================
log_step "Step 3: Deploying Keycloak instance (PostgreSQL + Keycloak + realm)"

# Detect cluster domain for Keycloak hostname
CLUSTER_DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
KEYCLOAK_HOSTNAME="keycloak-${KEYCLOAK_NS}.${CLUSTER_DOMAIN}"

oc apply -k "$SCRIPT_DIR/keycloak/instance/"

# Set the hostname so the RHBK operator creates an Ingress with a host,
# which OCP then auto-converts into a Route with edge TLS
log_info "Setting Keycloak hostname: ${KEYCLOAK_HOSTNAME}"
oc patch keycloak keycloak -n "$KEYCLOAK_NS" --type merge \
    -p "{\"spec\": {\"hostname\": {\"hostname\": \"${KEYCLOAK_HOSTNAME}\", \"strict\": false, \"strictBackchannel\": false}}}"

log_info "Waiting for PostgreSQL..."
oc rollout status deployment/keycloak-pgsql -n "$KEYCLOAK_NS" --timeout=120s

log_info "Waiting for Keycloak to be ready..."
for i in $(seq 1 90); do
    READY=$(oc get keycloak keycloak -n "$KEYCLOAK_NS" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
    if [ "$READY" = "True" ]; then
        log_info "Keycloak is ready"
        break
    fi
    if [ "$i" -eq 90 ]; then
        log_error "Timed out waiting for Keycloak"
        log_warn "Check: oc get keycloak keycloak -n $KEYCLOAK_NS -o yaml"
        exit 1
    fi
    sleep 5
done

log_info "Waiting for realm import..."
for i in $(seq 1 60); do
    DONE=$(oc get keycloakrealmimport maas -n "$KEYCLOAK_NS" -o jsonpath='{.status.conditions[?(@.type=="Done")].status}' 2>/dev/null || true)
    if [ "$DONE" = "True" ]; then
        log_info "Realm 'maas' imported"
        break
    fi
    if [ "$i" -eq 60 ]; then
        log_error "Timed out waiting for realm import"
        exit 1
    fi
    sleep 5
done

# =============================================================================
# Step 4: Get Keycloak issuer URL
# =============================================================================
log_step "Step 4: Discovering Keycloak issuer URL"

# Wait for Route to be created from the Ingress
KEYCLOAK_HOST=""
for i in $(seq 1 30); do
    KEYCLOAK_HOST=$(oc get route -n "$KEYCLOAK_NS" -o jsonpath='{.items[0].spec.host}' 2>/dev/null || true)
    if [ -n "$KEYCLOAK_HOST" ]; then
        break
    fi
    if [ "$i" -eq 30 ]; then
        log_error "No Route created for Keycloak"
        exit 1
    fi
    sleep 2
done

KEYCLOAK_ISSUER="https://${KEYCLOAK_HOST}/realms/maas"
log_info "Keycloak issuer URL: $KEYCLOAK_ISSUER"

# Verify the OIDC discovery endpoint
HTTP_CODE=$(curl -sSk -o /dev/null -w "%{http_code}" "${KEYCLOAK_ISSUER}/.well-known/openid-configuration" 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ]; then
    log_info "OIDC discovery endpoint is accessible"
else
    log_error "OIDC discovery endpoint returned HTTP $HTTP_CODE"
    exit 1
fi

# =============================================================================
# Step 5: Configure MaaS for OIDC
# =============================================================================
log_step "Step 5: Configuring MaaS tenant for external OIDC"
if [ "$RHOAI_35" = true ]; then
    oc patch aitenants.maas.opendatahub.io models-as-a-service -n "$AI_TENANTS_NS" \
        --type merge \
        -p "{\"spec\": {\"oidc\": {\"clientId\": \"maas-oidc\", \"issuerUrl\": \"${KEYCLOAK_ISSUER}\", \"ttl\": 300}}}"
    log_info "Patched AITenant with OIDC config"
else
    oc patch tenants.maas.opendatahub.io default-tenant -n "$MAAS_NS" \
        --type merge \
        -p "{\"spec\": {\"externalOIDC\": {\"clientId\": \"maas-oidc\", \"issuerUrl\": \"${KEYCLOAK_ISSUER}\"}}}"
    log_info "Patched Tenant with externalOIDC config"
fi

# =============================================================================
# Step 6: Create OIDC subscriptions and auth policies
# =============================================================================
log_step "Step 6: Creating MaaS subscriptions and auth policies for OIDC groups"
oc apply -k "$SCRIPT_DIR/maas-oidc/"
log_info "Created OIDC subscriptions and auth policies"

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "========================================="
echo "  Keycloak OIDC Setup Complete"
echo "========================================="
echo "  Keycloak URL:    https://${KEYCLOAK_HOST}"
echo "  Issuer URL:      ${KEYCLOAK_ISSUER}"
echo "  Client ID:       maas-oidc"
echo "  Realm:           maas"
echo ""
echo "  Test Users:"
echo "    maas-user / maas-user"
echo "      Groups: data-scientists, ml-engineers"
echo "    restricted-user / restricted-user"
echo "      Groups: data-scientists"
echo ""
echo "  Run test-external-oidc.sh to verify"
echo "========================================="
