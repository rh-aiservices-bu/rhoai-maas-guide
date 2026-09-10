# Gateway Telemetry (Reference Only)

These manifests are **reference only**. The RHOAI operator (`maas-controller`) auto-creates both resources when `spec.telemetry.enabled: true` is set on the MaasTenantConfig (3.5) or Tenant (3.4) CR.

You do not need to run `oc apply -k` on this directory.

## How to enable

```bash
# RHOAI 3.5+
oc patch maastenantconfig default-tenant -n models-as-a-service \
  --type=merge -p '{"spec":{"telemetry":{"enabled":true}}}'

# RHOAI 3.4
oc patch tenant default-tenant -n models-as-a-service \
  --type=merge -p '{"spec":{"telemetry":{"enabled":true}}}'
```

## What the operator creates

- **TelemetryPolicy** `maas-telemetry` - adds `model`, `subscription`, `organization_id`, and `cost_center` labels to gateway Prometheus metrics
- **Istio Telemetry** `latency-per-subscription` - adds `subscription` tag to `REQUEST_DURATION` metric

## Optional metric dimensions

The MaasTenantConfig/Tenant CRD supports additional metric toggles:

| Field | Default | Description |
|-------|---------|-------------|
| `captureModelUsage` | `true` | Model name in metrics |
| `captureOrganization` | `true` | Organization ID and cost center |
| `captureUser` | `false` | User ID (opt-in, GDPR implications) |
| `captureGroup` | `false` | Group membership |

See [Phase 7: Observability](../../content/modules/ROOT/pages/07-observability.adoc) for the full guide.
