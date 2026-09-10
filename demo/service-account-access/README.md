# ServiceAccount access to a model

An in-cluster workload calling a MaaS-governed model using its **own
ServiceAccount token** — no human identity, no external identity provider, and no
credential to distribute. Kubernetes projects the token into the pod; MaaS
validates it via TokenReview.

Requires MaaS deployed with the `simulator` model — from the repository root,
`./scripts/setup-maas.sh --model simulator`.

## How MaaS sees a ServiceAccount

A ServiceAccount token is issued by the Kubernetes API, not an IdP:

```
token sub: system:serviceaccount:maas-clients:batch-scorer
issued by: https://kubernetes.default.svc
```

It is validated by the `openshift-identities` method in the Authorino
`AuthConfig` (Kubernetes TokenReview), rather than the OIDC/JWT path. MaaS then
sees:

| Field | Value |
| --- | --- |
| username | `system:serviceaccount:<namespace>:<name>` |
| groups | `system:authenticated`, `system:serviceaccounts`, `system:serviceaccounts:<namespace>` |

Both are usable in MaaS objects, which is what makes the design below work.

## The design

Access is granted **once for the namespace**; the rate limit is **per workload**:

| Object | Effect |
| --- | --- |
| `MaaSAuthPolicy` on group `system:serviceaccounts:maas-clients` | every ServiceAccount in the namespace may call the model — no SA is named |
| `MaaSSubscription` per SA, matching `owner.users` | each workload gets its own limit |

| Workload | Subscription | Limit |
| --- | --- | --- |
| `batch-scorer` | `sa-batch-scorer-tier` | 120 tokens/min |
| `report-writer` | `sa-report-writer-tier` | 15 tokens/min |

## Run it

```bash
cd demo/service-account-access
./setup-demo.sh
./run-demo.sh
```

Verified output:

```
=== system:serviceaccount:maas-clients:batch-scorer ===
  token sub: system:serviceaccount:maas-clients:batch-scorer
  issued by: https://kubernetes.default.svc
  resolved subscription: sa-batch-scorer-tier
  inference with the SA token directly (no API key) -> HTTP 200
  burst 18 -> 11 ok / 7 rate-limited / 0 other

=== system:serviceaccount:maas-clients:report-writer ===
  resolved subscription: sa-report-writer-tier
  inference with the SA token directly (no API key) -> HTTP 200
  burst 18 -> 4 ok / 14 rate-limited / 0 other
```

Tear down with `./cleanup-demo.sh`.

## The app

`setup-demo.sh` also deploys `model-client`, a small app in the `maas-clients`
namespace that runs **as the `batch-scorer` ServiceAccount** and calls the model.

```bash
oc get route model-client -n maas-clients -o jsonpath='{.spec.host}'
oc logs -f deployment/model-client -n maas-clients
```

The page shows the identity the pod is running as, an *Ask the model* box, and a
*Burst 20 requests* button that trips the subscription's rate limit:

```
running as     system:serviceaccount:maas-clients:batch-scorer
token source   /var/run/secrets/kubernetes.io/serviceaccount/token

Ask            HTTP 200   usage: {'total_tokens': 37}
Burst 20       11 ok / 9 rate-limited   (39 tokens)
```

The thing to point at is what the manifest and the code do **not** contain:

```yaml
spec:
  serviceAccountName: batch-scorer     # the only line that sets its MaaS identity
```

```python
def sa_token():                        # re-read each call - kubelet rotates it
    with open("/var/run/secrets/kubernetes.io/serviceaccount/token") as f:
        return f.read().strip()

headers = {"Authorization": f"Bearer {sa_token()}"}
```

No API key, no client secret, nothing in a Secret, nothing to rotate. Change
`serviceAccountName` and the app lands in a different subscription with a
different rate limit — entitlement is a deployment-time decision, not a code one.

The code is delivered as a ConfigMap, so the demo needs no image build or
registry push. `setup-demo.sh --no-app` skips it.

> **Note:** the app skips TLS verification when calling MaaS, because the cluster
> ingress certificate is not in the base image's trust store. A production
> deployment would mount the CA bundle; the code marks the spot.

## Two ways a workload can call the model

Both work, and the choice matters for how you build the client:

1. **Straight with the ServiceAccount token** — no API key at all. Usually what you
   want in-cluster: the token is already mounted at
   `/var/run/secrets/kubernetes.io/serviceaccount/token`, rotated by Kubernetes,
   and there is nothing to store or revoke.
2. **Exchange it for a MaaS API key** — useful when the caller is outside the
   cluster, or when you want a credential with its own lifetime and revocation.

```bash
# in a pod, using the projected token
TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
curl -sk -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -X POST -d '{"model":"facebook/opt-125m","messages":[{"role":"user","content":"hi"}]}' \
  https://maas.<cluster-domain>/llm/facebook-opt-125m-simulated/v1/chat/completions
```

## Why each SA has its own subscription

The obvious design — one namespace-wide subscription plus higher-priority
per-SA overrides — hits a bug. **If an identity matches more than one
`MaaSSubscription`, the two call paths disagree:**

| Path | With overlapping subscriptions |
| --- | --- |
| token → API key → inference | works; resolves the higher priority correctly |
| ServiceAccount token used **directly** | **HTTP 403** |

Reproduced deliberately while building this demo: with both a namespace tier
(priority 20) and a per-SA tier (priority 70) matching `batch-scorer`, key
issuance returned `sa-batch-scorer-tier` correctly every time, but a direct token
call returned 403 consistently. Deleting the per-SA subscription — changing
nothing else — restored 200.

It is not the auth policies (removing the overlapping one did not help), not rate
limiting (403 rather than 429, and reproduced after the window reset), and not
specific to ServiceAccounts.

Keeping every identity matched to exactly one subscription avoids it entirely,
which is why the tiers here are per-SA rather than namespace-plus-override.

> **Note:** the same overlap exists for human users in the `user-level-rate-limiting`
> demo, where `alice` and `bob` match both a team tier and a per-user tier. Those
> demos only use the API-key path, so the problem stays latent there.

## Notes

- The inference body needs the *served* model name `facebook/opt-125m`, not the
  KServe resource name `facebook-opt-125m-simulated` (that is the URL path).
- Deleting a ServiceAccount does **not** revoke API keys already issued to it —
  those live in the MaaS database until they expire.
- `oc create token` mints a short-lived token for testing. A real workload uses
  the projected token in its pod, which Kubernetes rotates automatically.
