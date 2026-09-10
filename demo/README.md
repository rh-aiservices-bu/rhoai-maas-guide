# MaaS demos

Self-contained demos that run against a cluster with MaaS already deployed
(`./scripts/setup-maas.sh` from the repository root). Each folder has its own
README with a runbook, a talk track, and a teardown script.

## Before presenting

```bash
./preflight.sh
```

Read-only — it creates nothing and applies no YAML. It checks that every identity
can authenticate *and* resolves the subscription its demo expects, which are the
two things that break between sessions. It also sends a warm-up request, because
`maas-api` returns 500 on the first call after an idle period while it reopens
its database connection.

Expect `16 passed, 0 failed`. If anything fails it prints the fix.

> **Note:** setup is already applied on a prepared cluster — the demos themselves
> only read. The one exception is `jwks-cache/prove-cached.sh`, which applies a
> NetworkPolicy to cut Authorino off from the IdP; that *is* the demonstration,
> and it removes the policy again on exit.

## The demos

| Demo | Shows |
| --- | --- |
| [user-level-rate-limiting](user-level-rate-limiting/) | Assigning a `MaaSSubscription` to individual users as well as groups, and how `priority` resolves the overlap. Creates demo users via an htpasswd identity provider added alongside the cluster's existing one. |
| [oidc-authentication](oidc-authentication/) | Authenticating to MaaS with an external OIDC identity that has no OpenShift account, and using the token's `groups` claim to select a subscription. Also covers assigning access to an individual OIDC user with no group tier. Reuses an existing Keycloak rather than deploying a second one. Includes sample clients — a click-through UI and a CLI. |
| [service-account-access](service-account-access/) | An in-cluster workload calling a model with its own ServiceAccount token — validated by Kubernetes TokenReview, with no human identity and no external IdP. Access granted per namespace, rate limits per workload. |
| [jwks-cache](jwks-cache/) | That JWT signatures are genuinely verified (a forged token is rejected) and that validation happens locally from a cached JWKS — proven by cutting Authorino off from the IdP and showing tokens still validate. |
