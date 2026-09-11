# Tiering by group and by user

A `MaaSSubscription` sets a consumption tier — how many tokens an identity may
spend in a window. Subscriptions can be assigned to a **group**, to **individual
users**, or to both, with `priority` deciding which tier applies when a user
matches more than one.

That combination is what lets you set a team-wide default and then give a named
user their own tier without moving them out of the team.

Requires MaaS deployed with the `simulator` model — from the repository root,
`./scripts/setup-maas.sh --model simulator`.

## The mechanism

```yaml
spec:
  owner:
    groups:                  # []Object - each entry takes a `name` key
      - name: maas-demo-users
    users:                   # []string - plain usernames
      - alice
  priority: 30               # higher wins when a user matches several
```

## Cast

Three users, all members of the same group:

| User | Matches | Applied tier | Limit |
| --- | --- | --- | --- |
| `carol` | group only | `demo-team-standard` | 200 tokens/min |
| `alice` | group + user override | `demo-alice-gold` (priority 30) | 5000 tokens/min |
| `bob` | group + user override | `demo-bob-throttled` (priority 30) | 20 tokens/min |

`bob` is the one to demo live — at 20 tokens/min his limit engages after about
six requests, while `alice` and `carol` continue unaffected.

## Run it

```bash
cd demo/user-level-rate-limiting

# 1. Create alice/bob/carol and the maas-demo-users group
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
   `owner.groups` versus `owner.users`, and at `priority`.

2. **Mint a key as bob.** Note that the request does *not* name a subscription —
   the platform resolves it:

   ```bash
   oc login -u bob -p "$DEMO_PASSWORD" --server=$(oc whoami --show-server)
   curl -sk -H "Authorization: Bearer $(oc whoami -t)" -H 'Content-Type: application/json' \
     -X POST -d '{"name":"bob-demo","description":"demo","expiresIn":"8h"}' \
     "https://maas.$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')/maas-api/v1/api-keys" \
     | jq .subscription
   ```

   Returns `demo-bob-throttled` — MaaS selected the highest-priority match on its own.

3. **Run the burst** — bob receives 429 at his token limit; alice and carol sail through.
   Same model, same endpoint, same request: the difference is entitlement.

4. **Change a tier live** and re-run, to show tiers are policy rather than deployment:

   ```bash
   oc patch maassubscription demo-bob-throttled -n models-as-a-service --type=merge \
     -p '{"spec":{"modelRefs":[{"name":"facebook-opt-125m-simulated","namespace":"llm","tokenRateLimits":[{"limit":5000,"window":"1m"}]}]}}'
   ```

## How limits behave

- Limits are counted **per subscription**, not per API key. Issuing a second key
  does not reset the quota, so a user cannot lift their own ceiling by minting
  more credentials.
- Subscription ownership is **enforced**. A request naming a subscription the
  caller does not own is rejected.
- Limits are measured in **tokens**, not requests, so the quota reflects actual
  consumption rather than call count.

## Usage note

The URL path carries the KServe resource name (`facebook-opt-125m-simulated`)
and the request body carries the served model name (`facebook/opt-125m`):

```bash
curl ... -d '{"model":"facebook/opt-125m", ...}' \
  https://maas.<domain>/llm/facebook-opt-125m-simulated/v1/chat/completions
```
