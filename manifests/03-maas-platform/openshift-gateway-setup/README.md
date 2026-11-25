# OpenShift Gateway Setup (OPTIONAL)

This subdirectory is only needed for baremetal or OpenStack clusters where the
Gateway API LoadBalancer Service stays in Pending state because no cloud
load-balancer controller is available.

On AWS, GCP, or Azure clusters, the cloud load-balancer controller provisions
an external IP automatically and this directory can be skipped entirely. The
main MaaS setup script (scripts/setup-maas.sh) handles Gateway creation for
cloud environments.

## When you need this

If you deploy the MaaS Gateway and `oc get svc -n openshift-ingress` shows
the gateway service stuck in `Pending` with no EXTERNAL-IP, your cluster
needs MetalLB to provide a LoadBalancer IP, plus an OpenShift Route to make
the gateway reachable externally.

## Files

| File | Purpose |
|------|---------|
| `metallb-config.yaml` | IPAddressPool with `${METALLB_IP_RANGE}` placeholder + L2Advertisement |
| `gateway.yaml.tmpl` | Gateway with `${MAAS_HOSTNAME}` and `${CERT_NAME}` placeholders |
| `route.yaml.tmpl` | OpenShift Route with `${MAAS_HOSTNAME}` placeholder |
| `cleanup.yaml` | Deletes all gateway resources (Route, Gateway, MetalLB pool + advertisement) |
| `kustomization.yaml` | Only includes metallb-config.yaml (templates need envsubst) |

## Apply

### Step 1: Configure MetalLB

Edit `metallb-config.yaml` and replace `${METALLB_IP_RANGE}` with your
available IP range, or use envsubst:

```bash
export METALLB_IP_RANGE="192.168.1.240-192.168.1.250"
envsubst < manifests/03-maas-platform/openshift-gateway-setup/metallb-config.yaml | oc apply -f -
```

### Step 2: Create the Gateway

```bash
export CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
export MAAS_HOSTNAME="maas.${CLUSTER_DOMAIN}"
export CERT_NAME=$(oc get ingresscontroller default -n openshift-ingress-operator \
  -o jsonpath='{.spec.defaultCertificate.name}' 2>/dev/null)
export CERT_NAME=${CERT_NAME:-router-certs-default}

envsubst < manifests/03-maas-platform/openshift-gateway-setup/gateway.yaml.tmpl | oc apply -f -
```

### Step 3: Create the Route

```bash
envsubst < manifests/03-maas-platform/openshift-gateway-setup/route.yaml.tmpl | oc apply -f -
```

### Verify

```bash
# Gateway should be Programmed
oc get gateways -n openshift-ingress
oc wait --for=condition=Programmed gateway/maas-default-gateway -n openshift-ingress --timeout=60s

# LoadBalancer service should have an external IP
oc get svc -n openshift-ingress | grep maas

# Route should be created
oc get route -n openshift-ingress | grep maas
```

## Cleanup

```bash
oc delete -f manifests/03-maas-platform/openshift-gateway-setup/cleanup.yaml
```
