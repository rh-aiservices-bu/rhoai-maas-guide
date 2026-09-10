# MaaS external OIDC authentication demo

Shows a user who exists **only in Keycloak** — no OpenShift account, no `oc login` —
authenticating to MaaS, with the `groups` claim in their token deciding which
`MaaSSubscription` applies.

Requires MaaS already deployed with the `simulator` model — from the repository root,
`./scripts/setup-maas.sh --model simulator`.

## Do I need to deploy a Keycloak?

**No, if the cluster already runs one.** MaaS needs only an issuer URL and a client ID:

```yaml
spec:
  oidc:
    clientId: maas-oidc
    issuerUrl: https://<keycloak-host>/realms/maas
    ttl: 300
```

It does not care which Keycloak serves them. RHOAI demo clusters frequently already run
Red Hat Build of Keycloak — often as the cluster's own login provider — and a second
instance would mean a second database for no benefit.

`setup-oidc-demo.sh` finds the existing instance and imports the `maas` realm into it.
That realm is **new and isolated**: importing it does not modify any existing realm, and
the Keycloak pod is not restarted (the operator runs the import as a separate Job).

To deploy a standalone Keycloak instead, use the guide's own script:
`../../manifests/09-external-oidc/setup-keycloak.sh`.

## What gets created

Realm `maas`, from `realm-import.yaml`:

| Object | Detail |
| --- | --- |
| groups | `data-scientists`, `ml-engineers` |
| users | `maas-user` (both groups), `restricted-user` (`data-scientists` only) |
| client | `maas-oidc` — public, direct access grant, scopes `openid` + `groups` |

`add-solo-user.sh` optionally adds a third identity, `solo-user`, whose access
comes only from user-scoped objects — see
[User-scoped access, without a group tier](#user-scoped-access-without-a-group-tier).

Passwords equal the usernames. The custom **`groups` client scope** is the important
part: it puts group membership into the token, which is what `MaaSAuthPolicy` and
`MaaSSubscription` match on.

Then from `manifests/09-external-oidc/maas-oidc/`: two `MaaSAuthPolicy` objects granting
each group access to the simulator, and two `MaaSSubscription` objects
(`oidc-data-scientists` priority 10, `oidc-ml-engineers` priority 20).

## Run it

```bash
cd demo/oidc-authentication

./setup-oidc-demo.sh                          # auto-detects the existing Keycloak
./setup-oidc-demo.sh --keycloak-namespace keycloak   # or name it explicitly

./run-demo.sh
```

Verified output:

```
Issuer: https://sso.apps.<cluster-domain>/realms/maas
Client: maas-oidc

=== maas-user (exists only in Keycloak - no OpenShift account) ===
  token claims: preferred_username=maas-user groups=['data-scientists', 'ml-engineers']
  resolved subscription: oidc-ml-engineers
  inference: 5 requests -> 5 ok / 0 rate-limited / 0 other

=== restricted-user (exists only in Keycloak - no OpenShift account) ===
  token claims: preferred_username=restricted-user groups=['data-scientists']
  resolved subscription: oidc-data-scientists
  inference: 5 requests -> 5 ok / 0 rate-limited / 0 other
```

Tear down with `./cleanup-demo.sh`.

## User-scoped access, without a group tier

Subscriptions can be assigned to individual users as well as groups. `solo-user`
demonstrates it: they belong to one group, `no-tier`, which **no subscription
references**, so everything they can do comes from two user-scoped objects.

```bash
./add-solo-user.sh          # idempotent; creates the user, group and MaaS objects
./run-demo.sh               # solo-user now appears alongside the other two
```

```
=== solo-user ===
  token claims: preferred_username=solo-user groups=['no-tier']
  resolved subscription: solo-user-tier
```

The two objects, in `user-scoped-access.yaml`, are separate because access and
entitlement are separate decisions:

| Field | Decides |
| --- | --- |
| `MaaSAuthPolicy.subjects` | may they call the model at all |
| `MaaSSubscription.owner` | what tier (rate limit) they get |

Both take `users` as a plain `[]string` matched against the token's
`preferred_username`. `groups` entries are objects with a required `name` — an
asymmetry that is easy to get wrong.

### The catch: a user in zero groups cannot use MaaS

This is the part worth knowing before you build anything on user-scoped access.

`maas-api` rejects any request whose token carries no `groups` claim, and Keycloak
omits that claim entirely for a user who belongs to no group. The surfaced error
says nothing useful:

```
HTTP 500  {"error":"Exception thrown while generating token","exceptionCode":"AUTH_FAILURE"}
```

The real reason only appears in the log:

```bash
oc logs -n redhat-ai-gateway-infra deployment/maas-api | grep -i "group header"
#   "Missing group header"
```

So `owner.users` is not a standalone path. It resolves the *tier*, but the request
must first survive a check that requires the claim to exist. The workaround is the
`no-tier` group: membership of something — anything no subscription references —
satisfies the check while granting nothing.

Arguably a bug: an absent claim should read as an empty group list rather than
throw, and the error should say so. Compare requesting a subscription you do not
own, which returns a clean `400 invalid_subscription`.

> **Note:** Keycloak also refuses the direct grant with `"Account is not fully set up"`
> unless the user has an email address, because the realm's user profile requires
> one. `add-solo-user.sh` sets one.

## Sample client

`sample-app/maas-login.py` does the same thing as an application rather than a pile of
`curl` commands — browser login (authorization code + PKCE) or direct grant, exchanges
the OIDC token for a MaaS API key, and calls the model:

```bash
cd sample-app
./maas-login.py login --from-cluster      # opens a browser
./maas-login.py whoami
./maas-login.py chat "say hello in three words"
```

See [`sample-app/README.md`](sample-app/README.md).

## Talk track

1. **Point out these users have no OpenShift accounts** — `oc get users` does not list
   them. They exist only in the Keycloak `maas` realm.

2. **Get a token by direct grant** and decode it:

   ```bash
   ISSUER=$(oc get aitenants.maas.opendatahub.io models-as-a-service -n ai-tenants -o jsonpath='{.spec.oidc.issuerUrl}')
   TOKEN=$(curl -sSk -X POST "$ISSUER/protocol/openid-connect/token" \
     -d grant_type=password -d client_id=maas-oidc \
     -d username=maas-user -d password=maas-user -d scope=openid | jq -r .access_token)
   echo "$TOKEN" | jq -R 'split(".")[1] | @base64d | fromjson | {preferred_username, groups}'
   ```

   The `groups` claim is the thing to point at.

3. **Mint a MaaS API key with that token** — a Keycloak token, not an OpenShift one:

   ```bash
   curl -sSk -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
     -X POST -d '{"name":"demo","description":"demo","expiresIn":"1h"}' \
     "https://maas.$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')/maas-api/v1/api-keys" \
     | jq '{subscription}'
   ```

   Returns `oidc-ml-engineers` — resolved from the group claim.

4. **Contrast with `restricted-user`**, who is in one group and lands on
   `oidc-data-scientists`.

## Notes

- Both shipped OIDC subscriptions carry the same token limit (100000/min), so the
  visible difference is *which subscription resolves*, not throttling. To demo
  throttling as well, lower one of them:

  ```bash
  oc patch maassubscription oidc-data-scientists -n models-as-a-service --type=merge \
    -p '{"spec":{"modelRefs":[{"name":"facebook-opt-125m-simulated","namespace":"llm","tokenRateLimits":[{"limit":20,"window":"1m"}]}]}}'
  ```

- The inference body needs the *served* model name `facebook/opt-125m`, not the KServe
  resource name `facebook-opt-125m-simulated` (that is the URL path).

- The first request after an idle period can return HTTP 500 — a stale pooled DB
  connection in `maas-api`. `run-demo.sh` retries once; by hand, just resend.

- `cleanup-demo.sh` deletes the `KeycloakRealmImport` CR, but the realm itself may
  persist in the Keycloak database. Remove it from the admin console for a full reset.
