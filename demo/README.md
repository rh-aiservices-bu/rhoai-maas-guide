# MaaS demos

Four demos showing how Models as a Service governs access to a model: **who may
call it**, and **how much they may consume**.

Each demo runs against a cluster with MaaS deployed (`./scripts/setup-maas.sh`
from the repository root). Each folder contains a setup script, a README with a
runbook and a talk track, and a teardown script.

## The demos

| Demo | Shows |
| --- | --- |
| [user-level-rate-limiting](user-level-rate-limiting/) | Assigning a `MaaSSubscription` to a group or to an individual user, and using `priority` to give a named user a different tier from the rest of their team. |
| [oidc-authentication](oidc-authentication/) | Authenticating with an identity from your own identity provider — no OpenShift account required — with the token's `groups` claim selecting the subscription. Includes a click-through UI and a CLI sample client. |
| [service-account-access](service-account-access/) | An application calling a model with its own Kubernetes ServiceAccount token. No API key to distribute, no credential to rotate. Access granted per namespace, rate limits set per workload. |
| [jwks-cache](jwks-cache/) | That JWT signatures are genuinely verified, and that verification happens locally against a cached copy of the issuer's public keys rather than a call to the identity provider on every request. |

## Readiness check

```bash
./preflight.sh
```

Read-only — it creates nothing and applies no YAML. It confirms every identity
can authenticate and resolves the subscription its demo expects, and sends a
warm-up request so the first click of the demo is a warm one.

Expect `16 passed, 0 failed`.

Setup is applied once, ahead of time; the demos themselves only read. The single
exception is `jwks-cache/prove-cached.sh`, which applies a NetworkPolicy as the
demonstration itself and removes it again on exit.
