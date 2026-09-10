# MaaS tiering demo

Demonstrates how a `MaaSSubscription` is assigned to **groups** or to **individual
users**, and how `priority` resolves the overlap when a user matches both.

Requires MaaS already deployed with the `simulator` model — from the repository
root, `./scripts/setup-maas.sh --model simulator`.

## The mechanism

```yaml
spec:
  owner:
    groups:                  # []Object - each entry needs a `name` key
      - name: maas-demo-users
    users:                   # []string - PLAIN usernames, no `name` key
      - alice
  priority: 30               # higher wins when a user matches several
```

The asymmetry between `groups` and `users` is easy to get wrong: groups are objects,
users are bare strings.

## Cast

| User | Matches | Applied tier | Limit |
| --- | --- | --- | --- |
| `carol` | group only | `demo-team-standard` | 200 tokens/min |
| `alice` | group + user override | `demo-alice-gold` (priority 30) | 5000 tokens/min |
| `bob` | group + user override | `demo-bob-throttled` (priority 30) | 20 tokens/min |

`bob` is the one to demo live — 20 tokens/min trips after about six requests.

## Run it

```bash
cd demo/user-level-rate-limiting

# 1. Create alice/bob/carol and the maas-demo-users group.
#    Adds an htpasswd IdP alongside any existing provider; backs up oauth/cluster first.
./setup-demo-users.sh

# 2. Apply the tiers
oc apply -f subscriptions.yaml

# 3. Show it working
./run-demo.sh
```

Representative output:

```
=== carol ===  resolved subscription: demo-team-standard
  10 requests -> 10 ok / 0 rate-limited / 0 other   (39 tokens consumed)
=== alice ===  resolved subscription: demo-alice-gold
  10 requests -> 10 ok / 0 rate-limited / 0 other   (38 tokens consumed)
=== bob ===    resolved subscription: demo-bob-throttled
  10 requests -> 5 ok / 5 rate-limited / 0 other    (23 tokens consumed)
```

Tear down with `./cleanup-demo.sh`.

## Talk track

1. **Show `subscriptions.yaml`** — one group tier, two per-user overrides. Point at
   `owner.groups` vs `owner.users`, and at `priority`.

2. **Mint a key as bob**, noting the request does *not* name a subscription:

   ```bash
   oc login -u bob -p "$DEMO_PASSWORD" --server=$(oc whoami --show-server)
   curl -sk -H "Authorization: Bearer $(oc whoami -t)" -H 'Content-Type: application/json' \
     -X POST -d '{"name":"bob-demo","description":"demo","expiresIn":"8h"}' \
     "https://maas.$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')/maas-api/v1/api-keys" \
     | jq .subscription
   ```

   Returns `demo-bob-throttled` — MaaS resolved the highest-priority match itself.

3. **Run the burst** — bob hits 429 at his token limit; alice and carol sail through.

4. **Change a tier live** and re-run:

   ```bash
   oc patch maassubscription demo-bob-throttled -n models-as-a-service --type=merge \
     -p '{"spec":{"modelRefs":[{"name":"facebook-opt-125m-simulated","namespace":"llm","tokenRateLimits":[{"limit":5000,"window":"1m"}]}]}}'
   ```

## Two gotchas

**Model name.** The inference body needs the *served* model name `facebook/opt-125m`,
not the KServe resource name `facebook-opt-125m-simulated`. The resource name is the
URL path; the served name goes in the JSON body. Getting it wrong returns
`404 The model ... does not exist`.

**Cold-start 500.** The first request after an idle period can return HTTP 500 —
`maas-api` logs `database lookup failed: context canceled`, a stale pooled DB
connection. It retries fine and sustained traffic is stable. `run-demo.sh` retries once
on a 500, so the demo stays clean; if you demo by hand, just send the request again.

## Behaviour worth stating accurately

- Rate limits are counted **per subscription**, not per key. Minting a second key does
  not reset the quota — a fresh key on an exhausted subscription is throttled
  immediately.

- Subscription ownership is **enforced**. Requesting a subscription you do not own
  returns `400 {"code":"invalid_subscription"}`.

- A restrictive user tier is **not a ceiling**. If a user also matches a more permissive
  subscription, they can name it at key-creation time and bypass the restriction. Any
  subscription granting `system:authenticated` will match your demo users too, so check
  what else they match before demoing:

  ```bash
  oc get maassubscription -A \
    -o custom-columns=NAME:.metadata.name,GROUPS:.spec.owner.groups,USERS:.spec.owner.users,PRIO:.spec.priority
  ```
