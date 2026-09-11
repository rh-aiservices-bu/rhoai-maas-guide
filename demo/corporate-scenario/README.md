# Corporate scenario: division-level model governance

> **Full step-by-step guide**: see the [Corporate Scenario page](../../content/modules/ROOT/pages/corporate-scenario.adoc) in the Antora documentation.

A realistic scenario showing how a CIO might roll out MaaS across an organization.
Three divisions get differentiated access to a mix of on-prem and cloud models,
each with appropriate token budgets.

This goes beyond the "free tier / premium tier" pattern and into how you would
actually structure model governance for a company: who can see what, who pays
for what, and how the platform enforces it all through policy.

Requires MaaS deployed with the `simulator` model - from the repository root,
`./scripts/setup-maas.sh --model simulator`.

## The scenario

A CIO assigns three divisions access to AI models:

| Division | On-prem general purpose | On-prem code model (DeepSeek R2) | Cloud model (Gemini Flash) |
|----------|------------------------|----------------------------------|----------------------------|
| **Sales** | Yes (500 tok/min) | No | No |
| **Engineering** | Yes (500 tok/min) | Yes (1000 tok/min) | Yes (20 tok/min) |
| **Products** | Yes (500 tok/min) | Yes (500 tok/min) | No |

The cloud model is expensive, so only Engineering gets access - and with a tight
cap (20 tokens/min triggers rate limiting within a few requests). Engineering gets
higher limits on the code model because they use it more heavily. Sales only needs
the general purpose model.

Each division gets ONE subscription covering all their allowed models. This means
a single API key gives a user access to everything their division is entitled to.

## Models

All three models are backed by the CPU-only simulator - no GPU required.

| Model | Namespace | Type | Served name |
|-------|-----------|------|-------------|
| facebook-opt-125m-simulated | llm | On-prem (existing) | facebook/opt-125m |
| deepseek-r2-llmd | llm | On-prem | deepseek/deepseek-r2 |
| gemini-flash-cloud | cloud-models | Cloud | google/gemini-flash |

The namespace shows up in the URL path, which is how you visually distinguish
on-prem from cloud:
- On-prem: `https://maas.<domain>/llm/deepseek-r2-llmd/v1/chat/completions`
- Cloud: `https://maas.<domain>/cloud-models/gemini-flash-cloud/v1/chat/completions`

## Users

Six htpasswd users across three groups (IDP name: `corp-demo`):

| Group | Users | Division |
|-------|-------|----------|
| corp-sales | sales-1, sales-2 | Sales |
| corp-engineering | eng-1, eng-2 | Engineering |
| corp-products | prod-1, prod-2 | Products |

## Run it

```bash
cd demo/corporate-scenario

# 1. Create users, groups, models, and MaaS governance CRDs
./setup-demo.sh

# 2. Show it working - access control + rate limits per division
./run-demo.sh

# 3. Automated verification (access matrix, rate limits, key multiplication)
./verify-scenario.sh
```

Representative output from `run-demo.sh`:

```
=== sales-1 (corp-sales) ===
  Visible models:
    publishers/llm/models/facebook/opt-125m
  Resolved subscription: corp-sales
  General purpose (on-prem):
    8 requests -> 8 ok / 0 rate-limited / 0 other  (22 tokens)
  DeepSeek R2 (on-prem):
    deepseek-r2-llmd: 403 Forbidden (expected)
  Gemini Flash (cloud):
    gemini-flash-cloud: 403 Forbidden (expected)

=== eng-1 (corp-engineering) ===
  Visible models:
    publishers/cloud-models/models/google/gemini-flash
    publishers/llm/models/deepseek/deepseek-r2
    publishers/llm/models/facebook/opt-125m
  Resolved subscription: corp-engineering
  General purpose (on-prem):
    8 requests -> 8 ok / 0 rate-limited / 0 other  (21 tokens)
  DeepSeek R2 (on-prem):
    8 requests -> 8 ok / 0 rate-limited / 0 other  (27 tokens)
  Gemini Flash (cloud) - expect rate limiting at ~20 tokens/min:
    8 requests -> 6 ok / 2 rate-limited / 0 other  (20 tokens)

=== prod-1 (corp-products) ===
  Visible models:
    publishers/llm/models/deepseek/deepseek-r2
    publishers/llm/models/facebook/opt-125m
  Resolved subscription: corp-products
  General purpose (on-prem):
    8 requests -> 8 ok / 0 rate-limited / 0 other  (29 tokens)
  DeepSeek R2 (on-prem):
    8 requests -> 8 ok / 0 rate-limited / 0 other  (32 tokens)
  Gemini Flash (cloud):
    gemini-flash-cloud: 403 Forbidden (expected)
```

Tear down with `./cleanup-demo.sh`.

## Talk track

1. **Start with the CIO's problem.** Three divisions, each with different needs.
   Sales wants a chatbot, Engineering wants code assistance plus cloud model access,
   Products needs the code model for sprint reviews. How do you give each team
   exactly what they need - no more, no less?

2. **Show the manifests.** Open `auth-policies.yaml` and `subscriptions.yaml`.
   Point out how `MaaSAuthPolicy` controls visibility (who can see which models)
   and `MaaSSubscription` controls consumption (how much each group can use).
   The combination is the full governance picture.

3. **Show the model catalog per user.** Log in to the RHOAI Dashboard as each
   division user. Sales sees one model. Products sees two. Engineering sees all
   three. The platform hides what you cannot access - there is no "request access"
   button for models outside your policy.

   <!-- screenshots go here once captured -->

4. **Run the burst.** Point out that Engineering hits rate limiting on the cloud
   model (50 tokens/min) but not on the on-prem models. That is the CIO's intent:
   cloud is expensive, keep it tight. On-prem is cheaper, give them room.

5. **Try denied access.** Sales calling the DeepSeek model gets a clean 403. Not a
   500, not a timeout - the platform knows the policy and enforces it before the
   request reaches the model.

6. **Key multiplication does not help.** Run `verify-scenario.sh` and point at
   the key multiplication test. Minting a second API key does not reset the quota.
   The rate limit is per subscription, not per credential.

7. **Change a limit live.** Patch a subscription to show that governance is policy,
   not deployment:

   ```bash
   oc patch maassubscription corp-eng-cloud -n models-as-a-service --type=merge \
     -p '{"spec":{"modelRefs":[{"name":"gemini-flash-cloud","namespace":"cloud-models","tokenRateLimits":[{"limit":5000,"window":"1m"}]}]}}'
   ```

   Re-run `./run-demo.sh` - Engineering no longer hits rate limiting on the cloud
   model. No redeployment, no restart, instant policy change.

## How it works

### MaaSAuthPolicy - who can see what

Each `MaaSAuthPolicy` grants access to one or more models for specific groups or
users. If a user is not covered by any auth policy for a model, the model does not
appear in their catalog and API calls return 403.

The existing `simulator-access` policy grants `system:authenticated` access to the
general purpose model. The corporate policies add group-specific access to the two
new models without touching the existing setup.

### MaaSSubscription - how much they can use

Each division gets ONE `MaaSSubscription` covering all their allowed models,
with per-model token rate limits. When a user mints an API key, the platform
resolves the highest-priority subscription they match and attaches it - so one
key gives access to all models in the subscription.

All corporate subscriptions use priority 30 to outrank the shipped
`simulator-premium` (priority 20, targeting `system:authenticated`). Without this,
the shipped tier would win and the corporate limits would not apply.

### Priority resolution

- Subscriptions are **selected**, not accumulated. A user gets ONE subscription -
  the highest priority match.
- A single subscription can cover multiple models with different limits per model.
- Minting multiple API keys does not multiply the quota. Rate limits are per
  subscription, not per credential.
- Priority 30 for all corporate subscriptions means they win over shipped defaults
  (priority 10 and 20).

## What the verify script checks

| Test | What it proves |
|------|----------------|
| Access control (9 tests) | Full 3x3 matrix: 6 allow, 3 deny |
| Rate limiting (1 test) | eng-1 hits 429 on the 20 tok/min cloud model |
| Key multiplication (1 test) | Second key shares the first key's exhausted quota |
| Config drift (4 tests) | Subscription limits match expected values |

## Files

```
demo/corporate-scenario/
  README.md              # this file
  setup-demo.sh          # create users, groups, models, MaaS CRDs
  run-demo.sh            # interactive demo - access + rate limits per division
  verify-scenario.sh     # automated verification (15 tests)
  cleanup-demo.sh        # tear down all demo resources
  manifests/
    namespace-cloud-models.yaml
    model-deepseek-r2.yaml
    model-gemini-flash.yaml
    maas-model-deepseek-r2.yaml
    maas-model-gemini-flash.yaml
    auth-policies.yaml
    subscriptions.yaml
  screenshots/           # captured after setup on a live cluster
```
