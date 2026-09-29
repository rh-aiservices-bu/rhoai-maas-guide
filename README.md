# RHOAI Models-as-a-Service (MaaS) Guide

Guide to deploy RHOAI 3.4 / 3.5 Models-as-a-Service on OpenShift.

- Kustomize manifests with status gates between every phase
- Single automation script for end-to-end deployment
- CPU-only simulator model for validation without GPUs
- Disconnected (air-gapped) support with image mirroring
- External OIDC authentication with Keycloak
- AI-assisted installation via Claude Code, Cursor, and other tools

Requires OpenShift 4.19+ with cluster-admin access.

> **Note:** This guide is not a replacement for the official RHOAI MaaS documentation ([3.5](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/govern_llm_access_with_models-as-a-service/index) | [3.4](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html/govern_llm_access_with_models-as-a-service/index)). It is a companion resource with opinionated Kustomize manifests and automation scripts to accelerate deployment.

**Full documentation:** https://rh-aiservices-bu.github.io/rhoai-maas-guide/

## Phases

Each phase has step-by-step instructions, status gates, and troubleshooting.

### Installation Guide

| Phase | Description | Time |
|-------|-------------|------|
| [0. Disconnected Setup](https://rh-aiservices-bu.github.io/rhoai-maas-guide/modules/main/00-disconnected.html) *(optional)* | Air-gapped image mirroring, ITMS modelcars, GPU machineset | varies |
| [1. Prerequisites](https://rh-aiservices-bu.github.io/rhoai-maas-guide/modules/main/01-prerequisites.html) | Operator subscriptions (RHOAI, RHCL, cert-manager, LWS) | 5-10 min |
| [2. Platform Configuration](https://rh-aiservices-bu.github.io/rhoai-maas-guide/modules/main/02-platform-config.html) | Kuadrant/Authorino, User Workload Monitoring, GatewayClass, Gateway | 5-10 min |
| [3. MaaS Platform](https://rh-aiservices-bu.github.io/rhoai-maas-guide/modules/main/03-maas-platform.html) | PostgreSQL database and secrets | 5 min |
| [4. RHOAI Configuration](https://rh-aiservices-bu.github.io/rhoai-maas-guide/modules/main/04-rhoai-config.html) | DataScienceCluster, DSCInitialization, Dashboard settings | 5-10 min |

### Model Deployment & Verification

| Phase | Description | Time |
|-------|-------------|------|
| [5. Model Deployment](https://rh-aiservices-bu.github.io/rhoai-maas-guide/modules/main/05-maas-models.html) | Deploy and register LLM models with MaaS | 1-15 min |
| [6. Verification](https://rh-aiservices-bu.github.io/rhoai-maas-guide/modules/main/06-verification.html) | End-to-end checks (API keys, inference, rate limiting) | 5 min |

### Optional Phases

| Phase | Description | Time |
|-------|-------------|------|
| [7. Observability](https://rh-aiservices-bu.github.io/rhoai-maas-guide/modules/main/07-observability.html) | COO, Tempo, OpenTelemetry, Loki, Gateway telemetry | 5 min |
| [8. External Models](https://rh-aiservices-bu.github.io/rhoai-maas-guide/modules/main/08-external-models.html) | ExternalModel CRs for OpenAI, Gemini, Bedrock | 5-10 min |
| [9. External OIDC](https://rh-aiservices-bu.github.io/rhoai-maas-guide/modules/main/09-external-oidc.html) | Keycloak OIDC integration for corporate identity providers | 5-10 min |

### Reference

| Page | Description |
|------|-------------|
| [Architecture & Request Flow](https://rh-aiservices-bu.github.io/rhoai-maas-guide/modules/main/08-architecture.html) | End-to-end request flow through the MaaS gateway |
| [Model Swap](https://rh-aiservices-bu.github.io/rhoai-maas-guide/modules/main/11-model-swap.html) | Replace a deployed model without downtime |
| [Platform Upgrade (3.4 to 3.5)](https://rh-aiservices-bu.github.io/rhoai-maas-guide/modules/main/12-platform-upgrade.html) | Upgrade guide with post-upgrade troubleshooting |
| [Cleanup & Teardown](https://rh-aiservices-bu.github.io/rhoai-maas-guide/modules/main/09-cleanup.html) | Full MaaS removal |

## Automated Setup

A single script runs Phases 0-6 end-to-end. Each phase is idempotent - re-running skips what is already done.

```bash
# RHOAI 3.5 (default)
./scripts/setup-maas.sh

# RHOAI 3.4
./scripts/setup-maas.sh --rhoai-version 3.4
```

With optional phases:

```bash
# With observability
./scripts/setup-maas.sh --with-observability

# With external models (OpenAI, Gemini, Bedrock)
./scripts/setup-maas.sh --with-external-models

# With external OIDC (Keycloak)
./manifests/09-external-oidc/setup-keycloak.sh
```

Resume from a specific phase after a failure:

```bash
./scripts/setup-maas.sh --from-phase 4
```

See the [Automated Setup](https://rh-aiservices-bu.github.io/rhoai-maas-guide/modules/main/quick-start.html) page for all options and usage patterns.

## Available Models

| Model | GPU Required | VRAM | Use Case |
|-------|-------------|------|----------|
| `simulator` | No | None | Testing/demo (CPU-only) |
| `granite-tiny-gpu` | Yes | ~8 GiB | Small GPU (L4, L40) |
| `gemma` | Yes | ~12 GiB | Mid GPU (L4, L40, L40S) |
| `gpt-oss-20b` | Yes | >= 40 GiB | Large GPU (L40S, A100, H100) |

## Scripts

| Script | Description |
|--------|-------------|
| `scripts/setup-maas.sh` | Main orchestrator - end-to-end MaaS lifecycle (Phases 0-8) |
| `scripts/deploy-model.sh` | Standalone model deployment with GPU auto-detection |
| `scripts/test-inference.sh` | Send inference requests to a deployed model |
| `scripts/verify-maas.sh` | Wrapper for the 15-point E2E verification |
| `scripts/cleanup-maas.sh` | Full MaaS teardown |
| `manifests/09-external-oidc/setup-keycloak.sh` | Deploy Keycloak + configure OIDC |
| `manifests/09-external-oidc/test-external-oidc.sh` | 6-test OIDC verification |

## AI-Assisted Installation

If you use an AI coding tool ([Claude Code](https://claude.ai/code), [Open Code](https://opencode.ai), [Cursor](https://cursor.com), [Roo Code](https://roocode.com)), the `/install-maas` skill wraps the same script with an interactive, AI-assisted workflow:

```
/install-maas
```

See [AI-Assisted Installation](https://rh-aiservices-bu.github.io/rhoai-maas-guide/modules/main/claude-code.html) for details.

## Documentation

- [RHOAI 3.5 MaaS Official Docs](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/govern_llm_access_with_models-as-a-service/index)
- [RHOAI 3.4 MaaS Official Docs](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html/govern_llm_access_with_models-as-a-service/index)
- [Upstream MaaS Documentation](https://opendatahub-io.github.io/models-as-a-service/latest/)
- [Upstream MaaS Architecture](https://opendatahub-io.github.io/models-as-a-service/latest/concepts/architecture/)

## License

See [LICENSE](LICENSE).
