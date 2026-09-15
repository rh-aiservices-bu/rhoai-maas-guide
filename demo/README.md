# MaaS demos

Demos showing how Models as a Service governs access to models: **who may call
them**, **how much they may consume**, and **how clients reach them**.

Each demo runs against a cluster with MaaS deployed (`./scripts/setup-maas.sh`
from the repository root). Each folder contains a setup script, a README with a
runbook and a talk track, and a teardown script.

## The demos

| Demo | Shows |
| --- | --- |
| [user-level-rate-limiting](user-level-rate-limiting/) | Assigning a `MaaSSubscription` to a group or to an individual user, and using `priority` to give a named user a different tier from the rest of their team. |
| [subscription-priority](subscription-priority/) | That entitlement is selected rather than accumulated: a user in two groups worth 10000 and 20000 tokens/hour gets one of those tiers, not 30000 — and a subscription naming them individually can cap them below both. |
| [oidc-authentication](oidc-authentication/) | Authenticating with an identity from your own identity provider — no OpenShift account required — with the token's `groups` claim selecting the subscription. Includes a click-through UI and a CLI sample client. |
| [service-account-access](service-account-access/) | An application calling a model with its own Kubernetes ServiceAccount token. No API key to distribute, no credential to rotate. Access granted per namespace, rate limits set per workload. |
| [corporate-scenario](corporate-scenario/) | A realistic CIO assignment: three divisions (Sales, Engineering, Products) with differentiated access to on-prem and cloud models, each with appropriate token budgets. Full governance lifecycle from policy to verification. |
| [jwks-cache](jwks-cache/) | That JWT signatures are genuinely verified, and that verification happens locally against a cached copy of the issuer's public keys rather than a call to the identity provider on every request. |
| [single-url-access](single-url-access/) | One OpenAI-compatible endpoint and one API key for every model — two running on the cluster and one at an external provider — with the `model` field in the request body choosing the destination. Includes an OpenAI SDK example. |

## Readiness check

```bash
./preflight.sh
```

Read-only — it creates nothing and applies no YAML. It confirms every identity
can authenticate and resolves the subscription its demo expects, and sends a
warm-up request so the first click of the demo is a warm one.

Expect `19 passed, 0 failed`.

Setup is applied once, ahead of time; the demos themselves only read. The single
exception is `jwks-cache/prove-cached.sh`, which applies a NetworkPolicy as the
demonstration itself and removes it again on exit.

## Resetting quotas between rehearsals

```bash
./reset-quotas.sh
```

The demos that show a rate limit engaging spend real tokens, and the
hour-windowed ones in `subscription-priority` stay spent for an hour. Rate limit
counters are held in memory by Limitador, so restarting it returns every
subscription to a full allowance — which is what this does.

It is cluster-wide, clearing the counters for every subscription rather than one
demo's, and it clears counters rather than disabling limits.
