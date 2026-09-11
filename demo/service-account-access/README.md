# Application access with a ServiceAccount

An application calls a MaaS-governed model using its **own Kubernetes
ServiceAccount token**. No human identity, no external identity provider, and no
credential to distribute: Kubernetes projects the token into the pod and rotates
it, and MaaS validates it through TokenReview.

This is the pattern for anything that runs unattended — batch jobs, pipelines,
scheduled reports, agents.

Requires MaaS deployed with the `simulator` model — from the repository root,
`./scripts/setup-maas.sh --model simulator`.

## How MaaS sees a ServiceAccount

A ServiceAccount token is issued by the Kubernetes API:

```
token sub: system:serviceaccount:maas-clients:batch-scorer
issued by: https://kubernetes.default.svc
```

MaaS validates it with Kubernetes TokenReview and sees:

| Field | Value |
| --- | --- |
| username | `system:serviceaccount:<namespace>:<name>` |
| groups | `system:authenticated`, `system:serviceaccounts`, `system:serviceaccounts:<namespace>` |

Both are usable in MaaS objects, which is what makes the design below work.

## The design

Access is granted **once for the namespace**; the consumption tier is set **per
workload**:

| Object | Effect |
| --- | --- |
| `MaaSAuthPolicy` on group `system:serviceaccounts:maas-clients` | every ServiceAccount in the namespace may call the model — no SA is named |
| `MaaSSubscription` per SA, matching `owner.users` | each workload gets its own limit |

| Workload | Subscription | Limit |
| --- | --- | --- |
| `batch-scorer` | `sa-batch-scorer-tier` | 120 tokens/min |
| `report-writer` | `sa-report-writer-tier` | 15 tokens/min |

Deploying a new application into the namespace needs no access change — grant
access once to the team's namespace, then size each workload individually.

## Run it

```bash
cd demo/service-account-access
./setup-demo.sh
./run-demo.sh
```

Output:

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

Two workloads, same namespace, same model, different limits.

Tear down with `./cleanup-demo.sh`.

## The app

`setup-demo.sh` also deploys `model-client`, an application in the `maas-clients`
namespace that runs **as the `batch-scorer` ServiceAccount** and calls the model.

```bash
oc get route model-client -n maas-clients -o jsonpath='{.spec.host}'
oc logs -f deployment/model-client -n maas-clients
```

The page shows the identity the pod runs as, an *Ask the model* box, and a
*Burst 20 requests* button that reaches the subscription's rate limit:

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
def sa_token():                        # re-read each call - Kubernetes rotates it
    with open("/var/run/secrets/kubernetes.io/serviceaccount/token") as f:
        return f.read().strip()

headers = {"Authorization": f"Bearer {sa_token()}"}
```

No API key, no client secret, nothing in a Secret, nothing to rotate, nothing to
leak in a build log. Change `serviceAccountName` and the application lands in a
different subscription with a different limit — entitlement becomes a
deployment-time decision rather than a code change.

The application is delivered as a ConfigMap, so the demo needs no image build or
registry push. `setup-demo.sh --no-app` skips it.

## Two ways a workload can call the model

Both work, and the choice shapes how you build the client:

1. **Directly with the ServiceAccount token** — no API key at all. Usually what
   you want in-cluster: the token is already mounted at
   `/var/run/secrets/kubernetes.io/serviceaccount/token`, Kubernetes rotates it,
   and there is nothing to store, distribute or revoke.
2. **Exchanged for a MaaS API key** — useful when the caller sits outside the
   cluster, or when you want a credential with its own lifetime and revocation.

```bash
# in a pod, using the projected token
TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
curl -sk -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -X POST -d '{"model":"facebook/opt-125m","messages":[{"role":"user","content":"hi"}]}' \
  https://maas.<cluster-domain>/llm/facebook-opt-125m-simulated/v1/chat/completions
```

## Notes

- The URL path carries the KServe resource name
  (`facebook-opt-125m-simulated`); the request body carries the served model
  name (`facebook/opt-125m`).
- `oc create token` mints a short-lived token, which is how `run-demo.sh` tests
  each ServiceAccount from outside. A real workload uses the token projected
  into its pod, which Kubernetes rotates automatically.
