# One URL for every model

Applications reach every model through **one OpenAI-compatible endpoint**. The
`model` field in the request body chooses the destination — whether that model
runs on the cluster or at an external provider such as OpenAI.

```
https://maas.<cluster-domain>/v1/chat/completions
```

One base URL and one API key reach them all. Authentication, subscription checks
and token rate limits apply the same way to every model. Adding a model, or
moving one between the cluster and a provider, changes a `model` value in the
client's configuration, not its endpoint or its integration code.

## Prerequisites

MaaS deployed with the `simulator` model — from the repository root,
`./scripts/setup-maas.sh --model simulator`.

## What it sets up

Three models behind one subscription:

| Model ID | Kind | Runs |
| --- | --- | --- |
| `publishers/llm/models/facebook/opt-125m` | LLMInferenceService | on the cluster |
| `publishers/llm/models/RedHatAI/gemma-4-31B-it` | LLMInferenceService | on the cluster |
| `external-chat` | ExternalModel | at an external provider |

The external provider is an OpenAI-compatible simulator published on its own
HTTPS hostname, outside MaaS. MaaS reaches it exactly as it reaches
`api.openai.com`: through an `ExternalProvider` pointing at the hostname, with the
provider's API key held in a Secret. It replies by echoing the prompt, so a reply
shows the request travelled out to the provider and back.

| File | Creates |
| --- | --- |
| `local-model.yaml` | the second local model |
| `external-provider.yaml` | the stand-in provider (Deployment, Service, Route) |
| `external-model.yaml` | `ExternalProvider`, `ExternalModel`, `MaaSModelRef` |
| `access.yaml` | one `MaaSAuthPolicy` and one `MaaSSubscription` covering all three |

Access is granted to **you** (`oc whoami`), so the demo leaves every other
identity's entitlements unchanged.

## Run it

```bash
cd demo/single-url-access
./setup-demo.sh
./run-demo.sh
```

`setup-demo.sh` finishes by calling all three models through the shared endpoint,
and reports `Ready` once every one answers.

Output:

```
Endpoint   https://maas.apps.<cluster-domain>/v1/chat/completions
API key    sk-oai-xxxxxxxxxxx...   (subscription single-url-demo)

Models this key can reach  (GET /maas-api/v1/models)

  id                                                 kind                   where
  external-chat                                      ExternalModel          external provider
  publishers/llm/models/RedHatAI/gemma-4-31B-it      LLMInferenceService    on this cluster
  publishers/llm/models/facebook/opt-125m            LLMInferenceService    on this cluster

Same URL, same key - only "model" changes

  model: external-chat
    HTTP 200   served by: external-chat
    reply:     'Hello from the single URL'

  model: publishers/llm/models/RedHatAI/gemma-4-31B-it
    HTTP 200   served by: RedHatAI/gemma-4-31B-it
    reply:     'To be or not to be that is the question. Testing'

  model: publishers/llm/models/facebook/opt-125m
    HTTP 200   served by: facebook/opt-125m
    reply:     'The temperature here is twenty-five degrees centigrade. Alas'
```

The local simulators return canned text; the external provider echoes the prompt.

Tear down with `./cleanup-demo.sh`. It removes the second local model, the
external provider and model, and the subscription and auth policy, and leaves the
base `facebook-opt-125m-simulated` model in place.

## From an application

Any OpenAI-compatible client works unchanged. Point its base URL at MaaS and pass
the API key:

```python
from openai import OpenAI

client = OpenAI(
    base_url="https://maas.<cluster-domain>/v1",
    api_key="<MaaS API key>",
)

for model in ["publishers/llm/models/facebook/opt-125m",
              "publishers/llm/models/RedHatAI/gemma-4-31B-it",
              "external-chat"]:
    reply = client.chat.completions.create(
        model=model,
        messages=[{"role": "user", "content": "Hello from the OpenAI SDK"}],
        max_tokens=12,
    )
    print(model, "->", reply.choices[0].message.content)
```

Tested with the `openai` Python SDK: all three models answer through the one
client.

With `curl`, the request is identical for every model apart from `model`:

```bash
curl https://maas.<cluster-domain>/v1/chat/completions \
  -H "Authorization: Bearer $API_KEY" -H 'Content-Type: application/json' \
  -d '{"model": "external-chat", "messages": [{"role": "user", "content": "Hello"}]}'
```

## Model IDs

Use each model's ID exactly as `GET /maas-api/v1/models` returns it.

| Kind | ID format | Example |
| --- | --- | --- |
| Local (`LLMInferenceService`) | `publishers/<namespace>/models/<served name>` | `publishers/llm/models/RedHatAI/gemma-4-31B-it` |
| External (`ExternalModel`) | the `modelName` | `external-chat` |

A local model's ID includes its namespace, so two teams can serve the same model
in different namespaces and each keeps a distinct ID on the shared endpoint.

## How routing works

1. The gateway reads the `model` field from the request body into the
   `X-Gateway-Model-Name` header.
2. Each model's HTTPRoute matches its own ID in that header on the shared paths
   (`/v1/chat/completions`, `/v1/completions`, `/v1/responses`, `/v1/messages`).
3. Local models are served by their KServe workload. External models leave the
   cluster through an Istio `ServiceEntry` created for the provider's hostname,
   with the provider's API key added on the way out.

Each model also keeps its own per-model URL — `/llm/gemma-4-31b-it/v1/...` for a
local model, `/external-models/external-chat/v1/...` for an external one — for
clients that prefer a dedicated address.

## Connecting a real provider

`external-model.yaml` is the template. For OpenAI:

```yaml
spec:
  provider: openai
  endpoint: api.openai.com          # the provider's hostname
  auth:
    type: apikey
    secretRef:
      name: openai-api-key          # Secret holding the provider's API key
---
spec:
  modelName: gpt-4o-mini            # the provider's model identifier
  externalProviderRefs:
    - ref:
        name: openai
      targetModel: gpt-4o-mini      # same value as modelName
      apiFormat: openai-chat
      path: /v1/chat/completions
```

Create the Secret with the key `api-key` and the label
`inference.llm-d.ai/ipp-managed=true`. Set `modelName` to the provider's model
identifier — the same value as `targetModel` — and clients call it by that name.

See [Phase 8: External Models](../../content/modules/ROOT/pages/08-external-models.adoc)
for OpenAI, Gemini and AWS Bedrock manifests.

## Talk track

1. **Name the problem.** An organisation using several models typically ends up
   with a different URL, credential and SDK configuration for each one, and a
   separate one again for every external provider.

2. **Run `./run-demo.sh` and point at the model list.** Two models on this
   cluster, one at an external provider — all visible to a single API key.

3. **Point at the three calls.** Same endpoint, same key, same request. Only the
   `model` value changed, and each reply came from the model that was asked for.
   The external provider echoed the prompt back, so that request left the cluster
   and returned.

4. **Show the Python snippet.** A standard OpenAI client with one base URL. Swapping
   a local model for an external one — or back — is a change to a model name.

5. **Close on governance.** The external model is not a side door: it went through
   the same authentication, subscription check and token rate limit as the models
   running on the cluster.
