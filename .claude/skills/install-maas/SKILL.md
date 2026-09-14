---
name: install-maas
description: Install MaaS (Models as a Service) on a connected RHOAI cluster using this guide's Kustomize manifests and automation scripts.
argument-hint: "[--model simulator|granite-tiny-gpu|gemma|gpt-oss-20b|qwen3-06b|auto] [--from-phase N] [--skip-models] [--skip-verify] [--with-observability]"
allowed-tools: Bash(oc *), Bash(./*), Bash(envsubst *), Bash(curl *), Bash(jq *), Bash(grep *), Bash(ls *), Bash(cat *), Bash(date *), Bash(mkdir *), Bash(echo *), Bash(bash *), AskUserQuestion
---

# Install MaaS on Connected RHOAI Cluster

Install Models as a Service on an OpenShift cluster with RHOAI using this guide's all-in-one script. No ArgoCD required.

## Primary Entry Point

**`./scripts/setup-maas.sh`** is the single orchestrator that handles the entire lifecycle  - from operator installation through model deployment and verification. Each phase is idempotent; re-running skips what's already done.

```bash
./scripts/setup-maas.sh [OPTIONS]
```

## Arguments

- `--model <name>` -- Model to deploy: `simulator` (CPU), `granite-tiny-gpu` (small GPU), `gemma` (mid GPU), `gpt-oss-20b` (large GPU), `qwen3-06b` (real CPU, no GPU), `auto` (auto-detect). Default: `auto`.
- `--from-phase <N>` -- Start from phase N (0-7). Default: 0.
- `--skip-models` -- Skip Phase 5 (model deployment).
- `--skip-verify` -- Skip Phase 6 (verification).
- `--with-observability` -- Also run Phase 7 (COO + telemetry).
- `--dry-run` -- Preview without applying.

## Phases

| Phase | What it does | Time |
|-------|-------------|------|
| 0 | Preflight  - detect cluster state, decide which phases to run | instant |
| 1 | Operators  - `oc apply -k manifests/01-prerequisites/operators/`, wait for CSVs | 2-5 min |
| 2 | Platform  - Kuadrant, UWM, GatewayClass, envsubst Gateway | 2-5 min |
| 3 | RHOAI  - DSC with modelsAsService: Managed, Dashboard flags | 3-5 min |
| 4 | MaaS  - PostgreSQL secrets/deployment, Authorino TLS, wait for maas-api | 3-5 min |
| 5 | Model  - auto-detect GPU, apply Kustomize, wait for Ready | 0.5-15 min |
| 6 | Verify  - 6-phase E2E (API, auth, rate limits, cleanup) | 3-5 min |
| 7 | Observability  - COO subscription + Gateway TelemetryPolicy | 2-3 min |

## Instructions

Run from the guide repo root (`rhoai-maas-guide/`).

### Full Installation (Recommended)

For a fresh cluster with no MaaS components:

```bash
./scripts/setup-maas.sh
```

This runs Phases 0-6 automatically. The script detects what's already installed and skips completed phases.

### With Observability

```bash
./scripts/setup-maas.sh --with-observability
```

### Resume from a Specific Phase

If a previous run failed at Phase 4:

```bash
./scripts/setup-maas.sh --from-phase 4
```

### Models Only

If the platform is already installed and you just want to deploy a model:

```bash
./scripts/setup-maas.sh --from-phase 5
```

Or use the standalone model script for more control:

```bash
./scripts/deploy-model.sh --model simulator
```

### Verify Only

```bash
./scripts/setup-maas.sh --from-phase 6
```

Or directly:

```bash
./manifests/06-verification/verify.sh
```

## Convenience Scripts

These wrap individual phases for standalone use:

| Script | What it does |
|--------|-------------|
| `scripts/deploy-model.sh` | Phase 5 only  - deploy model with GPU auto-detection |
| `scripts/verify-maas.sh` | Phase 6 only  - wrapper for `manifests/06-verification/verify.sh` |

## State Detection

Phase 0 inspects the cluster and reports what's installed. The script uses this to skip phases:

- Operators installed? Skip Phase 1.
- Kuadrant + UWM + Gateway ready? Skip Phase 2.
- DSC with modelsAsService: Managed? Skip Phase 3.
- PostgreSQL + maas-api running? Skip Phase 4.
- Models deployed in llm namespace? Skip Phase 5.

Override with `--from-phase N` to force re-running from a specific phase.

## Troubleshooting

If a phase fails, the script reports what went wrong. Common fixes:

- **Operator CSV stuck**: Check `oc get csv -A --no-headers | grep -v Succeeded`
- **Gateway not Programmed**: Check `oc get gateway -n openshift-ingress -o yaml`
- **maas-api not appearing**: Check `oc get datasciencecluster default-dsc -o jsonpath='{.status.conditions}'`
- **Health endpoint 000**: DNS propagation for LoadBalancer  - wait 2-5 minutes
- **Model pods CrashLoopBackOff**: Check GPU resources with `oc describe pod -n llm`

## Final Report

The script ends with a summary: RHOAI version, MaaS API URL, Gateway status, health check, deployed models, and suggested next steps.
