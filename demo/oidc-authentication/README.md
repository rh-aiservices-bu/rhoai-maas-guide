# Authenticating with your own identity provider

Users authenticate to MaaS with an identity from your existing identity provider.
They need **no OpenShift account** — the `groups` claim in their token selects the
`MaaSSubscription` that applies, so entitlement follows the group structure you
already maintain.

Requires MaaS deployed with the `simulator` model — from the repository root,
`./scripts/setup-maas.sh --model simulator`.

## Using an existing Keycloak

MaaS needs only an issuer URL and a client ID:

```yaml
spec:
  oidc:
    clientId: maas-oidc
    issuerUrl: https://<keycloak-host>/realms/maas
    ttl: 300
```

It does not care which identity provider serves them, so a cluster that already
runs Red Hat Build of Keycloak — often as its own login provider — needs no
second instance.

`setup-oidc-demo.sh` finds the existing instance and imports the `maas` realm
into it. That realm is new and isolated: the import creates it alongside any
existing realms, leaves them untouched, and does not restart Keycloak.

To deploy a standalone Keycloak instead, use the guide's own script:
`../../manifests/09-external-oidc/setup-keycloak.sh`.

## What gets created

Realm `maas`, from `realm-import.yaml`:

| Object | Detail |
| --- | --- |
| groups | `data-scientists`, `ml-engineers` |
| users | `maas-user` (both groups), `restricted-user` (`data-scientists` only) |
| client | `maas-oidc` — public, direct access grant, scopes `openid` + `groups` |

The **`groups` client scope** is the important part: it places group membership
into the token, which is what `MaaSAuthPolicy` and `MaaSSubscription` match on.

Then from `manifests/09-external-oidc/maas-oidc/`: two `MaaSAuthPolicy` objects
granting each group access to the model, and two `MaaSSubscription` objects
(`oidc-data-scientists` priority 10, `oidc-ml-engineers` priority 20).

## Run it

```bash
cd demo/oidc-authentication

./setup-oidc-demo.sh                                 # auto-detects the existing Keycloak
./setup-oidc-demo.sh --keycloak-namespace keycloak   # or name it explicitly

./run-demo.sh
```

Output:

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

## Entitling an individual user

Access and tier can be granted to a named user directly, without adding them to
a group that carries entitlement. `solo-user` demonstrates it: their group
membership carries no subscription, so everything they can do comes from two
user-scoped objects in `user-scoped-access.yaml`.

```bash
./add-solo-user.sh          # idempotent; creates the user and the MaaS objects
./run-demo.sh               # solo-user now appears alongside the other two
```

```
=== solo-user ===
  token claims: preferred_username=solo-user groups=['no-tier']
  resolved subscription: solo-user-tier
```

The two objects are separate because access and entitlement are separate decisions:

| Field | Decides |
| --- | --- |
| `MaaSAuthPolicy.subjects` | may they call the model at all |
| `MaaSSubscription.owner` | what tier (rate limit) they get |

Both take `users` as a plain `[]string`, matched against the token's
`preferred_username`. `groups` entries are objects with a `name` key.

This is the pattern for a contractor, a pilot user, or anyone who needs a
different tier from everyone else with their job title.

## Sample clients

`sample-app/` contains a click-through UI and a CLI that do the same thing an
application would: sign the user in, exchange the OIDC token for a MaaS API key,
call the model.

```bash
cd sample-app
./maas-ui.py --from-cluster               # click-through UI, for demoing on screen
./maas-login.py login --from-cluster      # CLI, opens a browser
./maas-login.py chat "say hello in three words"
```

See [`sample-app/README.md`](sample-app/README.md).

## Talk track

1. **Point out these users have no OpenShift accounts** — `oc get users` does not
   list them. They exist only in the identity provider.

2. **Get a token** and decode it:

   ```bash
   ISSUER=$(oc get aitenants.maas.opendatahub.io models-as-a-service -n ai-tenants -o jsonpath='{.spec.oidc.issuerUrl}')
   TOKEN=$(curl -sSk -X POST "$ISSUER/protocol/openid-connect/token" \
     -d grant_type=password -d client_id=maas-oidc \
     -d username=maas-user -d password=maas-user -d scope=openid | jq -r .access_token)
   echo "$TOKEN" | jq -R 'split(".")[1] | @base64d | fromjson | {preferred_username, groups}'
   ```

   The `groups` claim is the thing to point at.

3. **Exchange it for a MaaS API key** — an identity provider token, not an
   OpenShift one:

   ```bash
   curl -sSk -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
     -X POST -d '{"name":"demo","description":"demo","expiresIn":"1h"}' \
     "https://maas.$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')/maas-api/v1/api-keys" \
     | jq '{subscription}'
   ```

   Returns `oidc-ml-engineers`, resolved from the group claim.

4. **Contrast with `restricted-user`**, who is in one group and lands on
   `oidc-data-scientists`. Nothing about the request changed — only the identity.

## Notes

- Tiers are policy, adjustable at any time. `setup-oidc-demo.sh` lowers
  `oidc-data-scientists` so the difference between the two tiers is visible
  during a burst; pass `--keep-shipped-limits` to leave the shipped values alone.

  ```bash
  oc patch maassubscription oidc-data-scientists -n models-as-a-service --type=merge \
    -p '{"spec":{"modelRefs":[{"name":"facebook-opt-125m-simulated","namespace":"llm","tokenRateLimits":[{"limit":20,"window":"1m"}]}]}}'
  ```

- The URL path carries the KServe resource name
  (`facebook-opt-125m-simulated`); the request body carries the served model
  name (`facebook/opt-125m`).
