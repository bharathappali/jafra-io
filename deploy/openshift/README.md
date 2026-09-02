# OpenShift install notes

Jafra workloads write JFR files to an `emptyDir` volume at `/jfr-data`. The
`jafra-agent` DaemonSet reads those files from the kubelet pod volume path on
each node (`/var/lib/kubelet/pods/...`). Only the agent needs elevated SCC on
OpenShift; opted-in Java Pods use standard restricted policies.

Use `./install-jafra.sh --target openshift` to apply the minimal platform bindings
and deploy the same manifests as Kind.

## Minimal permission model

### Cluster admin (one-time, or pre-apply manifests)

| Resource | Why |
|----------|-----|
| `MutatingWebhookConfiguration` | Admission webhook is cluster-scoped |
| cert-manager (optional) | Webhook TLS via `Certificate` CR |
| Custom SCC `jafra-agent` + RoleBinding | Agent mounts `/var/lib/kubelet/pods` |

Cluster admin can pre-apply (namespace **must** exist before SCC bindings):

```bash
kubectl apply -f deploy/controller/namespace.yaml
kubectl apply -f deploy/openshift/scc-jafra-agent.yaml   # SCC + ClusterRole (custom SCCs need both)
kubectl apply -f deploy/openshift/scc-platform.yaml
# cert-manager if not already present
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml
```

Or let the install script create the namespace and apply SCC bindings automatically:

```bash
./install-jafra.sh --target openshift --deploy-only
```

### Namespace admin (`jafra-system`)

Can run after admin prep:

```bash
./install-jafra.sh --target openshift --deploy-only
```

Needs permission to create/update in `jafra-system`:

- Deployments, DaemonSet, Service, PVC
- ServiceAccounts, Secrets (cert-manager)
- cert-manager `Issuer` / `Certificate` in the namespace

### Workload namespace admin

No extra SCC is required. Opted-in Java Pods only use `emptyDir` volumes injected
by the controller webhook.

## SCC map

| Component | SCC | Reason |
|-----------|-----|--------|
| `jafra-agent` | `jafra-agent` (custom) | hostPath to kubelet pod volumes; `spc_t` SELinux + root for MCS-crossing reads |
| `jafra-controller` | `nonroot` | Non-root image, no hostPath |
| `jafra-analyzer` | `nonroot` | PVC storage, non-root image |
| Opted-in app Pods | (default / restricted) | `emptyDir` recordings only |

## Install examples

Full install (namespace admin + SCC bind permission):

```bash
oc login ...
./install-jafra.sh --target openshift --install-cert-manager
```

Deploy only (images already in registry, admin prep done):

```bash
./install-jafra.sh --target openshift --deploy-only
```

Teardown:

```bash
./install-jafra.sh --target openshift --teardown
```

## Images

OpenShift pulls directly from the registry configured in manifests
(`quay.io/bharathappali/jafra-*`). No `kind load` step. Ensure nodes can pull
the images or configure `imagePullSecrets` on the ServiceAccounts.

## Troubleshooting

Pod admission failures mentioning SCC:

```bash
oc describe pod <name> -n jafra-system
oc get rolebinding -n jafra-system -l app.kubernetes.io/part-of=jafra
```

Opted-in app Pod fails on OpenShift:

```bash
oc describe pod <name> -n <app-namespace>
# Check webhook injection: emptyDir jafra-recordings volume and /jfr-data mount
```

Webhook not registered:

```bash
kubectl auth can-i create mutatingwebhookconfigurations --all-namespaces
kubectl apply -f deploy/controller/webhook.yaml
```
