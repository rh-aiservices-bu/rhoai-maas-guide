# JWKS validation and caching demo

Demonstrates the claim:

> Validates JWT tokens locally using cached JWKS (no call to the IdP on every request)

That is three separate assertions, and each needs its own evidence:

| Claim | How it is shown | Script |
| --- | --- | --- |
| fetches the issuer's public keys | the `AuthConfig` points Authorino at the issuer; discovery resolves `jwks_uri` | `run-demo.sh` |
| actually verifies signatures | a tampered token is rejected while the genuine one is accepted | `run-demo.sh` |
| validates *locally* from cache | Authorino is cut off from the IdP and validation keeps working | `prove-cached.sh` |

Requires the OIDC demo to be configured first — see [`../oidc-authentication/`](../oidc-authentication/).

## Where validation actually happens

Not in `maas-api`. MaaS renders `AITenant.spec.oidc` into a Kuadrant/Authorino
`AuthConfig`, and **Authorino** does the crypto:

```yaml
authentication:
  oidc-identities:
    jwt:
      issuerUrl: https://<keycloak>/realms/maas
      ttl: 300          # JWKS refresh interval - NOT a token lifetime
```

`ttl` is how often the background worker refreshes the keys. It is the single most
misread field here.

## Demo script

About five minutes. Two terminals side by side is ideal: one to run the scripts,
one to show the config. Do a warm-up run first — the first request after an idle
period can return 500 while `maas-api` reopens its database connection.

### Beat 1 — set up the claim (30s)

> "The gateway says it validates JWTs *locally*, using a *cached* JWKS, with no call
> to the identity provider on every request. That is really three claims, so let's
> take them one at a time — and let's not take any of them on trust."

### Beat 2 — where validation happens (45s)

```bash
oc get authconfig -n kuadrant-system -o yaml | grep -A4 'oidc-identities'
```

> "Validation isn't done by MaaS itself. MaaS renders its OIDC config into an
> Authorino AuthConfig, and Authorino does the crypto. Note `ttl: 300` — that is how
> often it refreshes the *keys*. It is not a token lifetime, which is the usual
> misreading."

### Beat 3 — the keys, and which one signed the token (60s)

```bash
./run-demo.sh
```

Point at two things as they scroll past:

> "Here are the public keys the issuer publishes — note the one marked `use=sig`,
> that's the signing key. And here's the header of a real token: it carries a `kid`,
> a key ID, and it matches. That is the link. Authorino looks up that key ID in the
> copy of the keys it already holds."

### Beat 4 — prove the signature is really checked (60s)

Same run, the section that matters:

> "Now the interesting part. I've taken a genuine token and rewritten the payload —
> I've promoted this user into `platform-admins`, a group they are not in — and left
> the original signature untouched."
>
> "Genuine token: 201. Forged token: 401."
>
> "Anyone can decode a JWT — it's base64, not encryption. What you cannot do is
> *sign* one. That's the whole security model, and it's why holding the issuer's
> public keys is what matters."

If someone asks "so could I just edit my groups claim?" — that question has just
been answered on screen.

### Beat 5 — prove it doesn't call the IdP (90s)

```bash
./prove-cached.sh
```

> "The last claim is the operational one: no call to the IdP per request. If that
> were false — if it phoned home every time — then cutting it off from the IdP would
> break it."
>
> "So: baseline first, 201. Now I apply a NetworkPolicy that blocks the Authorino
> pod from reaching the IdP's address. Watch the TCP connection fail — it genuinely
> cannot get there."
>
> "Same token, three more times: 201, 201, 201."
>
> "The identity provider is unreachable and validation still works. The only way
> that's possible is if the keys are already held locally. Then we remove the policy
> and we're back to normal."

Worth adding, because it is the honest caveat:

> "Keycloak is still running throughout — I only cut one pod's egress. And the token
> was issued *before* the block, so the only thing that would still need the IdP is
> the key lookup."

### Questions you should expect

| Question | Answer |
| --- | --- |
| "What if the keys rotate?" | The background worker re-fetches on the `ttl` interval — 300s here. A token signed by a new key fails until the next refresh, which is the trade-off you accept for not calling out per request. |
| "So it never talks to the IdP?" | It does — on a timer, not per request. That's the distinction the demo is making. |
| "Could I forge a token if I knew the `kid`?" | No. `kid` only says *which* public key to check against. You would need the matching private key, which never leaves the issuer. |
| "What happens if the IdP is down at startup?" | Then there is nothing cached yet and validation fails — which is exactly what we saw on this cluster this morning after a restart. Caching helps a running system ride out a blip; it is not a substitute for the IdP being available. |

## 1. Validation

```bash
cd demo/jwks-cache
./run-demo.sh
```

Read-only — it inspects config, fetches public keys, and sends two requests.

It prints the published keys and the `kid` from the token header, so you can show
they match:

```
  2 public key(s) published:
    kid=yM2nudvUT2JSANBnLytMpCUDhLqocO-gCjzn9xHubkU  alg=RSA-OAEP  use=enc
    kid=zQNnpBaoTZC1zqe6W4MoKTlaI3r411uK_dvwT09cnYw  alg=RS256     use=sig

  token header : kid=zQNnpBaoTZC1zqe6W4MoKTlaI3r411uK_dvwT09cnYw alg=RS256
```

Then the part worth pausing on — the payload is rewritten to promote the user into
a group they are not in, keeping the original signature:

```
  forged claims: groups=['ml-engineers', 'platform-admins']

  genuine token -> HTTP 201   (accepted)
  forged  token -> HTTP 401   (rejected)
```

Anyone can *decode* a JWT; only the issuer can *sign* one. That is the difference,
and it is why the cached public keys matter. It also pre-empts the obvious question
from the audience.

## 2. Caching

```bash
./prove-cached.sh
```

Applies a `NetworkPolicy` that blocks egress from the **Authorino pod only** to the
**IdP's address only**, then validates the same token again:

```
1. Baseline, IdP reachable        validate -> HTTP 201
2. Cut Authorino off              TCP to <idp-ip>:443 FAILED - blocked
3. Validate with IdP unreachable  201 / 201 / 201
4. Restore                        201
```

The argument is a contrapositive: **if Authorino called the IdP on every request,
step 3 would fail.** It does not, while step 2 proves the IdP genuinely is
unreachable from that pod. The token is minted *before* the block, so the only
thing still needing the IdP at validation time would be the key lookup.

Keycloak keeps running throughout, so cluster login is unaffected, and the script
has a `trap` so the policy is removed even if you interrupt it.

## Split-horizon DNS will fool you

This is the trap that produced a false pass while writing this demo. The IdP
hostname resolves differently inside and outside the cluster:

```
laptop     -> <public ingress IP>
in-cluster -> <cluster-internal IP>
```

Blocking the address your laptop sees leaves Authorino's real path wide open, and
validation "keeps working" for entirely the wrong reason. `prove-cached.sh`
resolves the hostname from a probe pod in `kuadrant-system` and blocks both
addresses. If you port this to another cluster, verify that first — a proof that
cannot fail is not a proof.

## If everything returns 503

Not a validation failure. The Envoy WASM shim failed to load and the filter is
configured fail-closed, so every request is refused before it reaches auth:

```bash
oc logs -n openshift-ingress -l gateway.networking.k8s.io/gateway-name=maas-default-gateway \
  | grep -i wasm
# critical envoy wasm ... Plugin configured to fail closed failed to load
# 503 ... wasm_fail_stream

oc delete pod -n openshift-ingress -l gateway.networking.k8s.io/gateway-name=maas-default-gateway
```

`run-demo.sh` detects this case and says so rather than reporting a pass.
