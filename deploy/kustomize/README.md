# Kustomize layouts

Workload manifests live under `base/`. Install scripts render image registry and
tags into `components/versions/kustomization.yaml` (gitignored; see
`components/versions/kustomization.yaml.example`) from `JAFRA_REGISTRY` and
`JAFRA_VERSION`.

## Phased apply (used by install / pull)

| Phase | Path | Contents |
|-------|------|----------|
| bootstrap | `phases/bootstrap` | namespace, controller RBAC, TLS certificate |
| controller | `phases/controller` | Service, Deployment (+ versions) |
| analyzer | `phases/analyzer` | PVC, analyzer Deployment |
| agent | `phases/agent` | agent RBAC, DaemonSet |

Cluster-scoped admission webhook: `deploy/controller/webhook.yaml` (applied after
controller rollout).

## Full stack overlay

`overlays/kind` and `overlays/openshift` include `base` plus the versions
component for one-shot `kubectl apply -k` (scripts use phased apply for
cert-manager ordering).

## OpenShift SCC

SCC manifests remain under `deploy/openshift/` and are applied by
`install-jafra.sh --target openshift` before workload phases.

## Manual smoke test

```bash
export JAFRA_VERSION=0.0.3-dev
source scripts/lib/common.sh
source scripts/lib/kustomize-versions.sh
write_versions_component
kubectl kustomize deploy/kustomize/phases/controller | grep image:
```
