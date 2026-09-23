# MCP servers in the gen AI playground

A model that can call tools is only useful if it has tools to call. This demo
deploys an **MCP server** and connects it to the Red Hat OpenShift AI gen AI
playground, so a tool-calling model served through MaaS can discover its tools
and invoke them from a chat prompt.

Ask *"What's the weather forecast for Dublin?"* and the model answers with a tool
call rather than prose. The playground executes it against a real MCP server
running on the cluster and feeds the result back into the conversation.

The demo is self-contained: the MCP server needs no credentials and no internet
access beyond its container image.

## Prerequisites

- MaaS deployed — from the repository root, `./scripts/setup-maas.sh`
- A **tool-calling model** reachable through MaaS. The simulator cannot do tool
  calling — it returns random text. Use an external model such as the one in
  [single-url-access](../single-url-access/), or any served model whose runtime
  supports the `tools` parameter.
- The **MCP Lifecycle Operator** enabled, which provides the `MCPServer` CRD:

  ```bash
  oc patch datasciencecluster default-dsc --type=merge \
    -p '{"spec":{"components":{"mcplifecycleoperator":{"managementState":"Managed"}}}}'
  ```

## What the setup does

| Step | Why |
| --- | --- |
| Enables the `ogx` DSC component | OGX is the playground backend from RHOAI 3.5 — it replaced LlamaStack. It defaults to `Removed`. Without it there is no playground, only the AI asset endpoints list. |
| Sets `dashboardConfig.genAiStudio: true` | Surfaces Gen AI studio in the dashboard. |
| Deploys an `MCPServer` | The sample weather server, `quay.io/rh-aiservices-bu/mcp-weather`. Deployed **into the same namespace as the OGX server**, so no NetworkPolicy is needed. |
| Creates ConfigMap `gen-ai-aa-mcp-servers` | This *is* the registration. The playground reads MCP servers from this one cluster-scoped ConfigMap in `redhat-ods-applications` — **not** from `MCPServerRegistration` objects. |

Run it:

```bash
./setup-demo.sh                 # defaults to the namespace holding your OGXServer
./setup-demo.sh --namespace llm # or name it explicitly
```

## Running the demo

```bash
./run-demo.sh
```

It verifies the server is answering and prints the runbook. Then, in the
dashboard:

1. **Gen AI studio → Playground**, select your project
2. **Settings → Model** — choose the tool-calling model and its subscription
3. **Settings → Streaming — turn it OFF** (see below; this is not optional)
4. **Settings → MCP** — the weather server appears. Click authorize and enter
   **any value**; this server has no authentication.
5. Prompt: *"What's the weather forecast for Dublin?"*

## Talk track

The point to land is that **two independent policy layers** are crossed in a
single prompt.

The MaaS side decides whether this identity may use this model at all, and how
many tokens it may spend — a `MaaSSubscription` and a `MaaSAuthPolicy`. Change
the subscription and the model disappears from the playground's list. This is
worth showing live: it is the same governance the API path enforces, visible in
a UI an end user actually touches.

The MCP side decides which tools exist and who may invoke them. This sample
server is deliberately open, so the contrast is easy to draw: put an MCP gateway
in front (see below) and tool access becomes per-identity, derived from role
claims in a token, entirely independently of the model's subscription.

Neither layer knows about the other. That is the design — model governance and
tool governance are separate concerns, composed at the point of use.

## Gotchas

Each of these produces a misleading error. They are why this demo has a runbook.

**Declare the transport.** The sample weather server speaks the legacy **SSE**
transport (`GET /sse` returns `event: endpoint, data: /message?sessionId=...`).
The playground defaults to streamable HTTP and will POST at the SSE endpoint,
getting a 404 that the UI reports as **"Authorization failed"**. The ConfigMap
entry must say so:

```json
{
  "url": "http://weather-mcp.<ns>.svc.cluster.local:3001/sse",
  "description": "...",
  "transport": "sse",
  "type": "sse"
}
```

Both keys are set because the warning it replaces (`Invalid or missing transport
type ... type=""`) does not make clear which one the parser reads. Setting both
is verified to work; if you isolate the correct single key, simplify this.

**"Authorization failed" rarely means authorization.** In building this demo it
meant a blocked NetworkPolicy once and a transport mismatch twice. Before
touching tokens, read the real error:

```bash
oc logs -n redhat-ods-applications deploy/gen-ai-ui | grep -i mcp
```

**This server ignores tokens.** It advertises no OAuth metadata and accepts any
`Authorization` header, so type anything into the authorize dialog. A gateway
fronted server is different — see below.

**Turn streaming off.** With streaming enabled, responses through the MaaS
gateway arrive complete — including `data: [DONE]` — and the stream is then never
closed. The playground waits, times out, and reports `Server error`. Confirmed
by A/B: the same upstream called directly streams cleanly, the same request
through the gateway hangs 3/3. Tracked upstream as Kuadrant wasm-shim issue
**#425**. Non-streaming is unaffected.

**The model must be in the subscription the playground selects.** An API key
resolves to exactly one subscription — the highest-priority match. If that
subscription does not list your tool-calling model, the call fails with a generic
server error. `GET /v1/models` with that key shows what it can actually see.

**The image hardcodes port 3001** and ignores `MCP_PORT`, and serves `/sse` — so
`spec.config.port` must be `3001` and `spec.config.path` `/sse`, or the
`MCPServer` advertises an address that does not answer.

## Alternative: behind an MCP gateway

The sample server is open by design, which keeps the demo simple but skips the
governance half of the story. To show per-identity tool authorization, register
the server with an **MCP gateway** (`MCPGatewayExtension` plus
`MCPServerRegistration`, from the MCP gateway Operator in Red Hat Connectivity
Link) and point the ConfigMap at the gateway instead of the server.

Three things change:

- The gateway normalises transport, so the `transport` keys are no longer needed.
- The playground's authorize dialog wants a **real** bearer token, and the tools
  the caller sees depend on `tool:` role claims inside it. A token with none —
  a realm `admin` account, typically — authorizes and then shows zero tools.
- Gateways are usually locked down to their own namespace, so both
  `redhat-ods-applications` **and** the OGX server's namespace need ingress on
  the gateway port. Allowing only the dashboard fails with a `TimeoutError` in
  the OGX pod and `Unexpected token '<'` in the browser, because the error page
  is HTML rather than JSON.

## Teardown

```bash
./cleanup-demo.sh
```

Removes the MCP server and the ConfigMap. It leaves `ogx` and `genAiStudio`
enabled, since other things may now depend on them — pass `--disable-ogx` to
revert those too.
