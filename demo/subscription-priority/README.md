# Subscription priority

Entitlement is **selected, not accumulated**. A user who belongs to two groups
worth 10000 and 20000 tokens per hour is not entitled to 30000 — MaaS ranks every
subscription the identity matches and applies the highest-priority one in full.

This is the question that comes up as soon as more than one team shares a model:
*what happens when someone is in several groups?* The answer is that quotas never
add up, and that a subscription naming an individual user outranks every group
they belong to — so an individual can also be capped **below** all of their group
tiers.

## Prerequisites

- MaaS deployed with the `simulator` model — from the repository root,
  `./scripts/setup-maas.sh --model simulator`
- The [OIDC demo](../oidc-authentication/), which imports the `maas` realm and
  points MaaS at it. `setup-demo.sh` checks for this and runs it if it is missing.

## The setup

Three subscriptions on one model:

| Subscription | Applies to | Limit | Priority |
| --- | --- | --- | --- |
| `quota-individual-tier` | user `capped-user` | 5000 tokens/hour | 50 |
| `quota-standard-tier` | group `quota-standard` | 10000 tokens/hour | 30 |
| `quota-bulk-tier` | group `quota-bulk` | 20000 tokens/hour | 20 |

Two users, with **identical group membership** — both belong to `quota-standard`
*and* `quota-bulk`:

| User | Matches | Resolves to | Entitlement |
| --- | --- | --- | --- |
| `dual-user` | both group tiers | `quota-standard-tier` (priority 30) | 10000 tokens/hour |
| `capped-user` | both group tiers **and** the user tier | `quota-individual-tier` (priority 50) | 5000 tokens/hour |

Two details make the point sharply:

- The higher-priority group tier is deliberately the **smaller** one. Joining a
  group with a larger allowance does not raise the ceiling.
- The individual tier is smaller still. Naming a user directly is how you set a
  cap that overrides whatever their team is entitled to.

## Run it

```bash
cd demo/subscription-priority
./setup-demo.sh
./run-demo.sh
```

`run-demo.sh` shows which subscription each user resolves to. It reads only, so
it is repeatable as often as you like:

```
   5000 tokens/hour   quota-individual-tier   priority 50   user  capped-user
  10000 tokens/hour   quota-standard-tier     priority 30   group quota-standard
  20000 tokens/hour   quota-bulk-tier         priority 20   group quota-bulk

Both users belong to BOTH groups.

=== dual-user ===
  groups claim: ['quota-bulk', 'quota-standard']
  resolved subscription: quota-standard-tier
  entitlement: 10000 tokens/hour  (not 30000 - the tiers do not add up)

=== capped-user ===
  groups claim: ['quota-bulk', 'quota-standard']
  resolved subscription: quota-individual-tier
  entitlement: 5000 tokens/hour  (not 30000 - the tiers do not add up)
```

## Proving the limit is real

`--burn` spends actual tokens until the quota is reached, so the ceiling is
demonstrated rather than asserted:

```bash
./run-demo.sh --burn
```

Verified output for `dual-user`:

```
=== dual-user ===
  groups claim: ['quota-bulk', 'quota-standard']
  resolved subscription: quota-standard-tier

  spending tokens (~970 per request, 25 requests maximum)...
     5 requests OK     4628 tokens spent
    10 requests OK     9310 tokens spent
    11 requests OK    10278 tokens spent   next request -> 429, quota reached

  stopped after 11 successful requests, ~10278 tokens
      5000  quota-individual-tier
     10000  quota-standard-tier  <- landed here
     20000  quota-bulk-tier
     30000  the two group tiers added together
```

Eleven requests, then 429. The ladder at the end is the whole argument: had the
two group tiers added up, the run would have continued past twenty requests.
`capped-user`, with the same group membership, stops at around five.

Each request carries a padded ~970-token prompt, so an hour's quota is reached in
a handful of calls rather than hundreds. A burn takes a few seconds.

> `--burn` spends the real hour-long window. Running it twice within the hour
> shows the quota already spent — the script says so plainly. The default mode
> consumes nothing and can be repeated freely, so rehearse with that.

Tear down with `./cleanup-demo.sh`, which removes the subscriptions, the auth
policy, and the two users and groups from the realm. The OIDC demo's own users
and the realm itself are left alone.

## Talk track

1. **Show the three subscriptions** and their priorities:

   ```bash
   # quoted, so zsh does not try to glob the [0] indexes
   oc get maassubscription -n models-as-a-service \
     quota-individual-tier quota-standard-tier quota-bulk-tier \
     -o 'custom-columns=NAME:.metadata.name,PRIORITY:.spec.priority,LIMIT:.spec.modelRefs[0].tokenRateLimits[0].limit,WINDOW:.spec.modelRefs[0].tokenRateLimits[0].window'
   ```

2. **Ask the question before showing the answer.** "This user is in a group worth
   10000 tokens an hour and another worth 20000. What are they entitled to?"
   30000 is the intuitive answer, and it is wrong.

3. **Run `./run-demo.sh`.** Point at the `groups` claim — both memberships are
   genuinely present in the token — and then at the resolved subscription. One
   subscription won; the other contributed nothing.

4. **Run `./run-demo.sh --burn`** and let it stop at eleven requests. The ladder
   printed at the end shows where the run would have ended under each alternative.

5. **Contrast `capped-user`.** Identical group membership, but a subscription
   names them directly at priority 50, so they get 5000 — less than either group
   tier. This is how you cap one person without touching their team's entitlement.

Expect one follow-up question: *what if two subscriptions have the same
priority?* The largest limit wins, so a tie resolves to the most permissive
tier — see [Designing priorities](#designing-priorities) for why a cap therefore
needs a strictly higher number.

## How resolution works

- **Highest `priority` wins.** The winning subscription becomes the entitlement in
  full; the others contribute nothing.
- **At equal priority, the largest limit wins.** A tie resolves toward the most
  permissive subscription, so priority is what restricts an identity — an equal
  number does not.
- **Group and user subscriptions rank in the same list.** A user subscription
  does not automatically beat a group one — it wins here because its priority is
  higher. Priority is the whole mechanism.
- **Limits are counted per subscription**, in tokens rather than requests, so the
  quota reflects real consumption.
- Callers do not name a subscription when requesting an API key. MaaS resolves it,
  which is why the same request produces a different entitlement for each user.

## Designing priorities

A workable convention, and the one used here:

| Band | Use |
| --- | --- |
| 10–29 | broad group tiers — the default entitlement for a team |
| 30–49 | narrower group tiers that should beat the defaults |
| 50+ | individual users — exceptions, caps, and pilots |

Two rules make this work:

**Give a restriction a strictly higher number.** Because a tie resolves to the
largest limit, an equal priority will not hold someone down. This demo depends on
it: `quota-individual-tier` caps `capped-user` at 5000 because it sits at priority
50, above both group tiers. Set it to 30 — tying with `quota-standard-tier` — and
the cap is ignored, because 10000 is the more permissive of the two.

**Leave gaps.** Inserting a tier between two existing ones is a one-line change if
the numbers are spaced, and a renumbering exercise if they are not.
