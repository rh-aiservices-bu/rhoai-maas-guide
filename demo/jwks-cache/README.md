# Local token validation with a cached JWKS

Demonstrates the claim:

> Validates JWT tokens locally using cached JWKS (no call to the IdP on every request)

That is three separate assertions, and each is shown with its own evidence:

| Claim | How it is shown | Script |
| --- | --- | --- |
| fetches the issuer's public keys | the `AuthConfig` points at the issuer; discovery resolves `jwks_uri` | `run-demo.sh` |
| genuinely verifies signatures | a tampered token is rejected while the genuine one is accepted | `run-demo.sh` |
| validates *locally* from cache | the identity provider is made unreachable and validation keeps working | `prove-cached.sh` |

Why it matters: token validation adds no round trip to the identity provider, so
inference latency does not depend on it, and a busy gateway does not turn into
load on your IdP.

Requires the OIDC demo to be configured first — see
[`../oidc-authentication/`](../oidc-authentication/).

## Where validation happens

MaaS renders `AITenant.spec.oidc` into a Kuadrant/Authorino `AuthConfig`, and
**Authorino** performs the signature check at the gateway:

```yaml
authentication:
  oidc-identities:
    jwt:
      issuerUrl: https://<keycloak>/realms/maas
      ttl: 300          # how often the public keys are refreshed
```

`ttl` is the JWKS refresh interval — how often a background worker re-fetches the
issuer's public keys. It is not a token lifetime.

## Demo script

About five minutes. Two terminals side by side works well: one to run the
scripts, one to show the configuration.

### Beat 1 — set up the claim (30s)

> "The gateway says it validates JWTs *locally*, using a *cached* JWKS, with no
> call to the identity provider on every request. That is really three claims, so
> let's take them one at a time — and let's not take any of them on trust."

### Beat 2 — where validation happens (45s)

```bash
oc get authconfig -n kuadrant-system -o yaml | grep -A4 'oidc-identities'
```

> "Validation isn't done by MaaS itself. MaaS renders its OIDC configuration into
> an Authorino AuthConfig, and Authorino does the cryptography, right at the
> gateway. Note `ttl: 300` — that is how often it refreshes the *keys*, not a
> token lifetime."

### Beat 3 — the keys, and which one signed the token (60s)

```bash
./run-demo.sh
```

Point at two things as they scroll past:

> "Here are the public keys the issuer publishes — note the one marked `use=sig`,
> that's the signing key. And here's the header of a real token: it carries a
> `kid`, a key ID, and it matches. That is the link. Authorino looks up that key
> ID in the copy of the keys it already holds."

### Beat 4 — prove the signature is really checked (60s)

Same run, the section that matters:

> "Now the interesting part. I've taken a genuine token and rewritten the payload
> — I've promoted this user into `platform-admins`, a group they are not in — and
> left the original signature untouched."
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

> "The last claim is the operational one: no call to the identity provider per
> request. If that were false — if it phoned home every time — then cutting it off
> from the IdP would break it."
>
> "So: baseline first, 201. Now I apply a NetworkPolicy that blocks the Authorino
> pod from reaching the IdP's address. Watch the TCP connection fail — it
> genuinely cannot get there."
>
> "Same token, three more times: 201, 201, 201."
>
> "The identity provider is unreachable and validation still works. The only way
> that's possible is if the keys are already held locally. Then we remove the
> policy and we're back to normal."

Worth adding, because it is the precise claim:

> "Keycloak is still running throughout — I only cut one pod's egress. And the
> token was issued *before* the block, so the only thing that would still need the
> IdP is the key lookup."

### Questions you should expect

| Question | Answer |
| --- | --- |
| "What if the keys rotate?" | The background worker re-fetches them on the `ttl` interval — 300s here, and configurable. Set it to match your issuer's rotation policy. |
| "So it never talks to the IdP?" | It does, on a timer rather than per request. That is the distinction the demo is making, and it is what keeps IdP load flat as inference traffic grows. |
| "Could I forge a token if I knew the `kid`?" | No. `kid` only says *which* public key to check against. You would need the matching private key, which never leaves the issuer. |
| "Does this add latency to inference?" | No round trip to the identity provider, so validation is a local signature check on the request path. |

## 1. Validation

```bash
cd demo/jwks-cache
./run-demo.sh
```

Read-only — it inspects configuration, fetches the public keys, and sends two
requests.

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
and it is why the cached public keys are what matter.

## 2. Caching

```bash
./prove-cached.sh
```

Applies a `NetworkPolicy` that blocks egress from the **Authorino pod only** to
the **identity provider's address only**, then validates the same token again:

```
1. Baseline, IdP reachable        validate -> HTTP 201
2. Cut Authorino off              TCP to <idp-ip>:443 FAILED - blocked
3. Validate with IdP unreachable  201 / 201 / 201
4. Restore                        201
```

The argument is a contrapositive: **if Authorino called the identity provider on
every request, step 3 would fail.** It does not, while step 2 proves the IdP
genuinely is unreachable from that pod. The token is minted *before* the block, so
the only thing still needing the IdP at validation time would be the key lookup.

Keycloak keeps running throughout, so cluster login is unaffected, and the script
removes the policy on exit — including if you interrupt it.

The script resolves the IdP's address from inside the cluster before blocking it,
so the proof holds on clusters where that hostname resolves differently inside
and outside.
