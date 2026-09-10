# Sample OIDC clients

Two sample clients showing what an application does instead of hand-rolling `curl`:
sign the user in, exchange the OIDC token for a MaaS API key, call the model.

| File | Use |
| --- | --- |
| `maas-ui.py` | **click-through UI** — run this to demo on screen |
| `maas-login.py` | CLI — same flow, for terminal-driven demos and scripting |

Standard library only — no `pip install`.

## The UI

```bash
cd demo/oidc-authentication/sample-app
./maas-ui.py --from-cluster            # opens http://localhost:8080
```

Four cards, each lighting up as you go:

1. **Sign in with Keycloak** — one button, opens the Keycloak login page
   (authorization code + PKCE). The password is never seen by the app.
2. **The token** — the decoded claims, with the `groups` values highlighted. This is
   the card to point at: entitlement comes from here.
3. **Exchanged for a MaaS API key** — which subscription resolved, and when it expires.
4. **Call the model** — a prompt box, plus a *Burst 15 requests* button that shows the
   rate limit for that user's tier as a green/amber bar.

Use *Switch user* to sign in as the other user and run the same burst:

| User | Subscription | Burst 15 |
| --- | --- | --- |
| `maas-user` | `oidc-ml-engineers` (100000 tokens/min) | 15 ok / 0 limited |
| `restricted-user` | `oidc-data-scientists` (20 tokens/min) | 7 ok / 8 limited |

Same button, same cluster — different result, decided by the token's `groups` claim.

> **Note:** `setup-oidc-demo.sh` lowers `oidc-data-scientists` to 20 tokens/min so this
> contrast is visible. Both shipped tiers are 100000/min, which throttles nothing. Pass
> `--keep-shipped-limits` to leave them alone.

It must listen on localhost — the `maas-oidc` client registers `http://localhost:*`
as its redirect URI. Model calls are proxied through the app rather than made from the
browser, so a self-signed cluster certificate does not interrupt the demo.

Options: `--port 8080`, `--no-browser`, `--model-served`, `--model-path`.

## The CLI

### Why this exists

The raw flow needs three `curl` invocations, a JWT decode and manual variable juggling.
Applications do not work that way. This shows the same three steps as an app:

```
  login  ──► OIDC token  ──► exchange ──► MaaS API key ──► inference
```

### Usage

```bash
cd demo/oidc-authentication/sample-app

# Browser login (authorization code + PKCE) - the realistic flow.
# Opens a browser; the password is never typed into the terminal.
./maas-login.py login --from-cluster

# Or the direct access grant - no browser, good for scripted demos.
MAAS_PASSWORD=maas-user ./maas-login.py login --from-cluster --password --username maas-user

./maas-login.py whoami
./maas-login.py chat "say hello in three words" -v
```

`--from-cluster` reads the issuer, client ID and MaaS URL from the cluster with `oc`,
purely as a demo convenience. A real client is *given* these as configuration:

```bash
export MAAS_ISSUER=https://sso.apps.<domain>/realms/maas
export MAAS_CLIENT_ID=maas-oidc
export MAAS_URL=https://maas.apps.<domain>
./maas-login.py login
```

### What it prints

```
$ ./maas-login.py login --from-cluster --password --username maas-user
Signed in as maas-user
  groups: ['data-scientists', 'ml-engineers']
  issuer: https://sso.apps.<domain>/realms/maas

MaaS API key issued -> subscription 'oidc-ml-engineers' (expires 2026-09-10T05:03:00Z)
Saved to ~/.maas/credentials.json

$ ./maas-login.py whoami
user:         maas-user
groups:       ['data-scientists', 'ml-engineers']
subscription: oidc-ml-engineers
api key:      sk-oai-XyOS20yHqBl...

$ ./maas-login.py chat "say hello in three words"
Testing, testing 1,2,3...
```

The simulator runs in `--mode random`, so responses are canned text rather than a real
completion. That is the model, not the client.

### The demo beat

Run `login` as `maas-user`, then again as `restricted-user`. Same command, same cluster —
different subscription, decided entirely by the `groups` claim in the token:

| User | groups claim | subscription |
| --- | --- | --- |
| `maas-user` | `data-scientists`, `ml-engineers` | `oidc-ml-engineers` |
| `restricted-user` | `data-scientists` | `oidc-data-scientists` |

## Notes

- **Decoding is not verifying.** `decode_claims()` reads the JWT payload for display
  only — it checks no signature. MaaS validates the signature against the issuer's
  JWKS. A forged token decodes fine and is then rejected.
- **TLS verification is disabled** because demo clusters use self-signed certificates.
  A production client would verify; the code marks the spot.
- **Retries once on 5xx.** `maas-api` can return 500 on the first call after an idle
  period (a stale pooled DB connection). The retry succeeds, so the client absorbs it.
- Credentials are written to `~/.maas/credentials.json` with mode `0600`. It holds a
  live API key — treat it as a secret.
- Both login modes were tested against this realm. The browser flow uses PKCE `S256`
  and a `http://localhost:<random-port>/callback` redirect, which the `maas-oidc`
  client already permits.
