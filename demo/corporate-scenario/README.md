# Fed Aura Capital: division-level model governance

> **Full step-by-step guide**: see the [Fed Aura Capital Scenario page](../../content/modules/ROOT/pages/corporate-scenario.adoc) in the Antora documentation.

A realistic scenario showing how a CIO might roll out MaaS across an
organization: 80,000 people, seven divisions, one gateway. Every division gets
differentiated access to a mix of on-prem and cloud models, each with hourly
token caps that encode the cost model.

This goes beyond the "free tier / premium tier" pattern and into how you would
actually structure model governance for a company: who can see what, who pays
for what, and how the platform enforces it all through policy.

Requires MaaS deployed with the `simulator` model - from the repository root,
`./scripts/setup-maas.sh --model simulator`. ~200m CPU and 512Mi memory per
model - the whole scenario runs on one CPU node.

## The scenario

The CIO assigns seven divisions access to six fake models. The philosophy, and
the line to say out loud: *caps are a property of cost, not of capability.*
On-prem models run on GPUs the bank already bought - CAPEX - so their caps
are generous. Cloud models are rented per token - so their caps are tight. IT
gets roughly five times the standard caps because it runs the platform and the
pilots.

| Division | GPT-OSS 120B | Kimi K3 | Nemotron Lightning 30B | Claude Opus 5.1 | Gemini 3 Pro | Terra |
|----------|--------------|---------|------------------------|-----------------|--------------|-------|
| **Sales** | - | - | - | 250K/h | - | - |
| **Branch** | 2M/h | - | - | - | - | - |
| **Credit / Loans** | 2M/h | - | - | - | - | - |
| **Developers** | 2M/h | 1M/h | 1M/h | - | - | - |
| **IT** | 10M/h | 5M/h | 5M/h | 1.25M/h | 250K/h | 500K/h |
| **Risk** | 2M/h | - | - | - | - | - |
| **Marketing** | - | - | - | 250K/h | 50K/h | - |

Each division gets ONE `MaaSSubscription` covering all of its allowed models.
Users mint their own API keys; every key a user holds carries the division tier.

## Models

All six "models" are backed by the CPU-only `llm-d-inference-sim` - no GPU
required. The catalog display name comes from the `MaaSModelRef` annotation;
the served name comes from `LLMInferenceService.spec.model.name`; the URL path
uses the namespace, which is how on-prem and cloud are visually separated:

- On-prem: `https://maas.<domain>/llm/kimi-k3/v1/chat/completions`
- Cloud: `https://maas.<domain>/cloud-models/claude-opus-5-1/v1/chat/completions`

| Display name | Role | Namespace | LLMInferenceService | Served name |
|--------------|------|-----------|---------------------|-------------|
| GPT-OSS 120B | General purpose | `llm` (on-prem) | `gpt-oss-120b` | `gpt-oss/120b` |
| Kimi K3 | Code | `llm` (on-prem) | `kimi-k3` | `kimi/k3` |
| Nemotron Lightning 30B | General purpose, lighter/faster | `llm` (on-prem) | `nemotron-lightning` | `nemotron/3.5-lightning` |
| Claude Opus 5.1 | General purpose | `cloud-models` (cloud) | `claude-opus-5-1` | `claude/opus-5.1` |
| Gemini 3 Pro | Image generation / multimodal | `cloud-models` (cloud) | `gemini-3-pro` | `gemini/3-pro` |
| Terra | Large-context general | `cloud-models` (cloud) | `terra-large-context` | `terra/large-context` |

The on-prem display names are real open-weight models published at
[huggingface.co/RedHatAI](https://huggingface.co/RedHatAI) - `gpt-oss-120b`,
`Kimi-K3`, `NVIDIA-Nemotron-3.5-Lightning-30B-A3B` - so a real deployment swaps
the simulator containers for real serving stacks and leaves every policy,
subscription, and user untouched.

## Users

14 htpasswd users across seven groups (two per division - the second user is
what makes the workshop's key-multiplication exercise possible). Identity
provider: `fedaura-demo`, additive - existing providers are untouched.

| Group | Users | Data class |
|-------|-------|------------|
| fedaura-sales | sales-1, sales-2 | Public-facing |
| fedaura-branch | branch-1, branch-2 | Public-facing |
| fedaura-credit | credit-1, credit-2 | Sensitive |
| fedaura-developers | dev-1, dev-2 | Technical |
| fedaura-it | it-1, it-2 | Technical |
| fedaura-risk | risk-1, risk-2 | Sensitive |
| fedaura-marketing | marketing-1, marketing-2 | Public-facing |

## Run it

```bash
cd demo/corporate-scenario

# 1. Build the environment: 14 users, 7 groups, htpasswd IdP, cloud-models
#    namespace, six LLMInferenceServices, MaaS CRDs (model refs, auth
#    policies, subscriptions). DEMO_PASSWORD='...' skips the interactive prompt.
./setup-demo.sh

# 2. Walk the video beats from the CLI (scenes 3-5)
./run-demo.sh

# 3. Prepare scene 6: burn IT's Claude Opus 5.1 hourly quota until a real 429
./warmup-cloud-quota.sh

# 4. Prove the whole 7x6 matrix holds
./verify-fa-cap.sh

# 5. Tear everything down
./cleanup-demo.sh
```

NOTE: the oauth pods restart after the identity provider is added. Wait about a
minute before logging in as the demo users.

Representative output from `run-demo.sh`:

```
=== sales-1 (fedaura-sales) ===
  Visible models:
    publishers/cloud-models/models/claude/opus-5.1
    publishers/llm/models/facebook/opt-125m
  Resolved subscription: fedaura-sales
  One inference per allowed model:
    claude-opus-5-1        200 OK  (5 tokens)

=== dev-1 (fedaura-developers) ===
  Visible models:
    publishers/llm/models/facebook/opt-125m
    publishers/llm/models/gpt-oss/120b
    publishers/llm/models/kimi/k3
    publishers/llm/models/nemotron/3.5-lightning
  Resolved subscription: fedaura-developers
  One inference per allowed model:
    gpt-oss-120b           200 OK  (3 tokens)
    kimi-k3                200 OK  (3 tokens)
    nemotron-lightning     200 OK  (8 tokens)

=== it-1 (fedaura-it) ===
  Visible models:
    publishers/cloud-models/models/claude/opus-5.1
    publishers/cloud-models/models/gemini/3-pro
    publishers/cloud-models/models/terra/large-context
    publishers/llm/models/facebook/opt-125m
    publishers/llm/models/gpt-oss/120b
    publishers/llm/models/kimi/k3
    publishers/llm/models/nemotron/3.5-lightning
  Resolved subscription: fedaura-it
  One inference per allowed model:
    gpt-oss-120b           200 OK  (4 tokens)
    kimi-k3                200 OK  (8 tokens)
    nemotron-lightning     200 OK  (6 tokens)
    claude-opus-5-1        200 OK  (8 tokens)
    gemini-3-pro           200 OK  (3 tokens)
    terra-large-context    200 OK  (2 tokens)

=== Scene 4 - the admin view: caps are a property of cost ===
  One subscription per division, per-model hourly limits:
  fedaura-developers:
    gpt-oss-120b (llm): 2000000 tokens / 1h
    kimi-k3 (llm): 1000000 tokens / 1h
    nemotron-lightning (llm): 1000000 tokens / 1h
  fedaura-marketing:
    claude-opus-5-1 (cloud-models): 250000 tokens / 1h
    gemini-3-pro (cloud-models): 50000 tokens / 1h
  ...

=== Scene 5 - the developer's day: copy URL + key ===
  Provider name:        Red Hat AI
  Base URL:             https://maas.<domain>/v1
  API key (dev-1):      sk-oai-...
  Kimi K3 endpoint:     https://maas.<domain>/llm/kimi-k3/v1/chat/completions
  Live token meter (input and output counted):
    prompt=7 completion=8 total=15 tokens
```

**Two model-ID details the IDE scene depends on:**

- The catalog lists full tenancy-prefixed IDs
  (`publishers/<namespace>/models/<served-name>`). Requests to the root
  `/v1/chat/completions` endpoint must use those, not the bare served name.
- The base guide's simulator model (`facebook/opt-125m`) stays visible to every
  authenticated user via the shipped `simulator-access` policy. Division keys
  calling it get a clean 403 - no division subscription covers it - so the
  matrix at the API level stays exact. For the video, the presenter simply does
  not select it.

## Talk track

1. **Start with the CIO's problem.** 80,000 people, seven divisions. Last
   quarter, every one of them had an AI subscription the bank paid for and
   could not see. *Who sees what - and what they can spend - lives in one
   place I control. Not buried in application code nobody can audit.*

2. **Show the manifests.** Open `auth-policies.yaml` and `subscriptions.yaml`.
   `MaaSAuthPolicy` controls visibility (who can see which models);
   `MaaSSubscription` controls consumption (how much each division can spend,
   per model, per hour). The combination is the full governance picture.

3. **Show the model catalog per user** (scene 3). The developer sees the on-prem
   models. The marketer sees the cloud general-purpose model plus the image
   model. The credit officer sees one on-prem general model. The platform hides
   what you cannot access - no "request access" button, no greyed-out rows. The
   catalog is the policy.

   <!-- screenshots go here once captured -->

4. **Show the admin view** (scene 4). One subscription per division,
   human-readable names, per-model hourly limits. Caps are a property of cost:
   on-prem is CAPEX (hardware already paid for, generous), cloud is rented per token (tight).

5. **Run the developer's day** (scene 5). Copy the base URL and key, add the
   "Red Hat AI" OpenAI-compatible provider, the dropdown populates with only the
   division's allowed models, the token meter climbs in real time. The whole
   integration is copy-and-paste - the developer never sees a cluster.

6. **Prove the guardrail** (scene 6). `./warmup-cloud-quota.sh` burns IT's
   Claude Opus 5.1 hourly quota until the gateway rate-limits - the 429 on
   camera is real, earned exhaustion of a real cap. The dropdown switches to the
   on-prem GPT-OSS 120B and generation continues, uninterrupted: the cloud cap
   does not touch on-prem.

7. **Key multiplication does not help.** `verify-fa-cap.sh` proves minting a
   second API key does not reset the quota: the cap is per user - all of a
   user's keys share one bucket - not per credential. (A second user in the
   same division gets their own budget; the cap is not pooled per division.)

8. **Change a limit live.** Governance is policy, not deployment:

   ```bash
   oc patch maassubscription fedaura-developers -n models-as-a-service --type=json \
     -p '[{"op":"replace","path":"/spec/modelRefs/1/tokenRateLimits/0/limit","value":10000000}]'
   ```

   Re-run `./run-demo.sh` - the new cap is in effect immediately. No code ships.
   Nothing redeploys.

## How it works

### MaaSAuthPolicy - who can see what

Each `MaaSAuthPolicy` grants access to one or more models for specific groups.
If a user is not covered by any auth policy for a model, the model does not
appear in their catalog and API calls return 403. There is one policy per
division, granting exactly the models in the matrix above.

The base guide's shipped `simulator-access` policy grants `system:authenticated`
access to `facebook-opt-125m-simulated`; the Fed Aura policies add
group-specific access to the six fake models without touching it.

### MaaSSubscription - how much they can spend

Each division gets ONE `MaaSSubscription` covering all of its models, with
per-model token rate limits and hourly windows (`window: 1h`). When a user
mints an API key, the platform resolves the highest-priority subscription they
match and attaches it - so every key they hold gives access to all models in
the subscription.

### Priority resolution

- Subscriptions are **selected**, not accumulated. A user gets ONE subscription
  - the highest priority match.
- All Fed Aura subscriptions use priority 30 to outrank the shipped
  `simulator-free` (10) and `simulator-premium` (20), both targeting
  `system:authenticated`. Without this, the shipped tier would win and the
  division caps would not apply.
- A single subscription covers multiple models with different limits per model.

### Quota scope - per user, not per credential

The hourly cap applies per user: all of a user's API keys share one bucket.
Minting a second key does not reset the quota. A different user in the same
division gets their own budget against the same subscription cap - quotas are
not pooled per division. (`verify-fa-cap.sh` proves both behaviors.)

## What the verify script checks

| Test | What it proves |
|------|----------------|
| Access control (42 tests) | Full 7x6 matrix: 15 allow, 27 deny |
| Rate limiting (1 test) | Marketing's Gemini 3 Pro hits 429 at its 50K/h cap - real exhaustion, not a mock |
| Key multiplication (2 tests) | A second key shares the user's exhausted quota; a second user in the same division gets their own budget |
| Config drift (16 tests) | All 15 subscription caps match the matrix; all windows are hourly |

`SKIP_RATE_LIMIT=1` skips the ~1-2 minute quota burn (the rate-limit and
key-multiplication tests then report SKIP).

## Files

```
demo/corporate-scenario/
  README.md              # this file
  setup-demo.sh          # create users, groups, IdP, models, MaaS CRDs
  run-demo.sh            # video beats CLI - catalogs, admin view, IDE config
  warmup-cloud-quota.sh  # burn a cloud model's hourly quota for a real 429
  verify-fa-cap.sh       # automated verification (61 tests)
  cleanup-demo.sh        # tear down all demo resources
  manifests/
    namespace-cloud-models.yaml
    models-onprem.yaml       # gpt-oss-120b, kimi-k3, nemotron-lightning (llm)
    models-cloud.yaml        # claude-opus-5-1, gemini-3-pro, terra-large-context (cloud-models)
    maas-models.yaml         # 6 MaaSModelRefs with catalog display names
    auth-policies.yaml       # one MaaSAuthPolicy per division
    subscriptions.yaml       # one MaaSSubscription per division, hourly caps
  materials/             # video assets M1-M5 (email, architecture, org chart, access matrix, cut card)
  screenshots/           # captured after setup on a live cluster
```
