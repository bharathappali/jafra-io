# Jafra

**J**VM **A**dvanced **F**light **R**ecording with **A**sync-profiler.

Jafra profiles Java workloads in Kubernetes by injecting
[async-profiler](https://github.com/async-profiler/async-profiler) into opted-in
Pods, collecting rotated JFR chunks from the node, and analyzing them
centrally. CPU, allocation, lock, GC, and compilation data land in the same
`.jfr` file when `jfrsync=default` is enabled.

This repository is the umbrella: Kubernetes manifests, the ingest protobuf, and
git submodules for the three runtime components.

```text
opt-in Java Pod
    → jafra-controller injects async-profiler
    → node-local JFR files under /var/lib/jafra/recordings
    → jafra-agent streams finalized chunks
    → jafra-analyzer stores, stitches, and reports
    → (optional) async-profiler MCP server for LLM agents
```

## Clone

```bash
git clone --recurse-submodules https://github.com/bharathappali/jafra-io.git
```

If the parent is already cloned:

```bash
git submodule update --init --recursive
```

For MCP support with `./pull-jafra.sh --mcp`, also clone the MCP server next to
this repo (gitignored reference tree):

```bash
git clone https://github.com/khansaad/Async-MCP.git Async-MCP
```

## Submodules

| Component | Role |
|---|---|
| [jafra-controller](https://github.com/bharathappali/jafra-controller) | Mutating admission webhook. Opt-in Pods get async-profiler, a recording volume, and `JAVA_TOOL_OPTIONS`. See the [controller README](jafra-controller/README.md). |
| [jafra-agent](https://github.com/bharathappali/jafra-agent) | Node-local collector (DaemonSet). Watches JFR files, streams finalized chunks to the analyzer, and deletes closed rotations after ack. See the [agent README](jafra-agent/README.md). |
| [jafra-analyzer](https://github.com/bharathappali/jafra-analyzer) | Quarkus service. Accepts ingest over gRPC, persists and stitches recordings, and serves HTTP `/report` and `/summary`. See the [analyzer README](jafra-analyzer/README.md). |

Each submodule is its own git repository. Commit and push there first, then
update the SHA recorded in this parent.

## This repository

- `contracts/` — canonical `jafra.proto` shared by agent and analyzer. See
  [contracts/README.md](contracts/README.md).
- `deploy/` — Kubernetes manifests for the controller, agent, analyzer, and
  example workloads (`namespace.yaml` first).
- `build-jafra.sh` — build component images with Podman.
- `install-jafra.sh` — build (if needed) from source, load into Kind, deploy.
- `pull-jafra.sh` — pull published images, load into Kind, deploy (optional MCP).

---

## Scripts: when to use what

All three scripts assume a Kind cluster named `jafra` (override with
`KIND_CLUSTER`). Create it once:

```bash
kind create cluster --name jafra
```

### Quick chooser

| You want to… | Use |
|---|---|
| Build images only (amd64 / arm64 / both), maybe push to Quay | [`build-jafra.sh`](#build-jafrash) |
| Develop locally: change submodule code, build, deploy to Kind | [`install-jafra.sh`](#install-jafrash) |
| Install from published Quay images (no local compile) | [`pull-jafra.sh`](#pull-jafrash) |
| Also run the async-profiler MCP server for agents | [`pull-jafra.sh --mcp`](#pull-jafrash) |
| Tear down Kind Jafra (+ optional cert-manager / MCP) | `pull-jafra.sh --teardown` or `install-jafra.sh --teardown` |

### Comparison

| | `build-jafra.sh` | `install-jafra.sh` | `pull-jafra.sh` |
|---|---|---|---|
| **Primary job** | Build container images | Build (if missing) + Kind deploy | Pull published images + Kind deploy |
| **Image source** | Podman build from Dockerfiles | `docker build` from source | `docker pull` from Quay |
| **Deploys to Kind?** | No | Yes | Yes |
| **Needs network to Quay for images?** | Only if `--push` or pulling bases | For base images during build | Yes (pull component images) |
| **Default registry / tags** | `quay.io/bharathappali/jafra-*:0.1.0` | `quay.io/bharathappali/jafra-*:0.1.0` | `quay.io/causa-ai-hub/jafra-*:0.1.0` |
| **Multi-arch (amd64 + arm64)** | Yes (`--multi-platform`) | No (host/`docker build` only) | N/A (uses whatever was published) |
| **MCP server** | No | No | Yes (`--mcp`) |
| **cert-manager helper** | No | `--install-cert-manager` | `--install-cert-manager` (+ owned teardown) |
| **Force refresh** | `--no-cache` | `--force-build` | `--force-pull` |
| **Skip image step** | N/A | `--deploy-only` | `--deploy-only` |
| **Teardown** | N/A | `--teardown` (Jafra only) | `--teardown` (Jafra + MCP; cert-manager if script-owned) |
| **Best for** | CI / publishing images | Day-to-day submodule development | Demo / install from published bits |

Typical flows:

```text
Change code in jafra-* submodules
    → ./install-jafra.sh --force-build
    → test on Kind

Publish multi-arch images
    → JAFRA_REGISTRY=quay.io/causa-ai-hub ./build-jafra.sh --multi-platform --push

Install on Kind from Quay (+ MCP)
    → ./pull-jafra.sh --install-cert-manager --mcp
```

---

### `build-jafra.sh`

Builds controller, agent, and analyzer images with **Podman**. Compilers run on
the host/VM architecture (`BUILDPLATFORM`) and cross-link for the target
platform so Apple Silicon does not run `rustc` under qemu (which often SIGSEGVs).

**Use when:** you need images for Linux nodes or Quay, without deploying.

```bash
# Single arch (default: linux/amd64)
./build-jafra.sh --platform linux/amd64

# Native arm64 (e.g. Kind on Apple Silicon)
./build-jafra.sh --platform linux/arm64

# Both arches: :0.1.0-amd64, :0.1.0-arm64, and :0.1.0 as a manifest list
./build-jafra.sh --multi-platform

# One component + push
JAFRA_REGISTRY=quay.io/causa-ai-hub ./build-jafra.sh --component agent --platform linux/amd64 --push
```

| Option | Meaning |
|---|---|
| `--platform <list>` | `linux/amd64`, `linux/arm64`, or comma-separated |
| `--multi-platform` | Build both amd64 and arm64; version tag is a dual-arch manifest |
| `--component <name>` | `controller` \| `agent` \| `analyzer` \| `all` |
| `--no-cache` | Pass `--no-cache` to Podman |
| `--push` | Push arch tags and the version manifest |

**Env:** `JAFRA_VERSION`, `JAFRA_REGISTRY` (default `quay.io/bharathappali`), `JAFRA_PLATFORM`.

Agent and analyzer **must** be built from the repo root so `contracts/` is in
the build context.

---

### `install-jafra.sh`

Local **dev install**: if images are missing, build them with Docker from the
submodule Dockerfiles, `kind load` them, then apply `deploy/` manifests and
switch the agent to gRPC mode.

**Use when:** you are editing `jafra-controller` / `jafra-agent` / `jafra-analyzer`
and want Kind to run what you just built.

```bash
./install-jafra.sh
./install-jafra.sh --force-build
./install-jafra.sh --install-cert-manager
./install-jafra.sh --deploy-only
./install-jafra.sh --teardown
```

| Option | Meaning |
|---|---|
| *(none)* | Build only if image missing, load, deploy |
| `--force-build` | Rebuild all three images, then load + deploy |
| `--deploy-only` | Apply manifests only (images already in Kind) |
| `--install-cert-manager` | Install cert-manager first (required for the webhook cert) |
| `--teardown` | Remove Jafra resources from the cluster |

**Env:** `KIND_CLUSTER` (default `jafra`), `JAFRA_VERSION` (default `0.1.0`).

Default image names: `quay.io/bharathappali/jafra-{controller,agent,analyzer}:0.1.0`.

Does **not** deploy the MCP server. For MCP, use `pull-jafra.sh --mcp` (or apply
the Async-MCP Kind manifest yourself after the analyzer is up).

---

### `pull-jafra.sh`

**Install from published images**: `docker pull` from Quay, `kind load`, deploy.
No compile step. Optionally deploys the
[async-profiler MCP server](https://github.com/khansaad/Async-MCP), which calls
`jafra-analyzer` over in-cluster DNS.

**Use when:** you want a working Kind stack from quay without building, or you
need MCP for LLM tools (`get_jfr_summary`, `get_recording_report`, …).

```bash
./pull-jafra.sh
./pull-jafra.sh --force-pull
./pull-jafra.sh --install-cert-manager --mcp
./pull-jafra.sh --deploy-only --mcp
./pull-jafra.sh --teardown
./pull-jafra.sh --teardown --uninstall-cert-manager
```

| Option | Meaning |
|---|---|
| *(none)* | Pull missing images, load, deploy Jafra |
| `--force-pull` | Always re-pull images, then load + deploy |
| `--deploy-only` | Apply manifests only |
| `--install-cert-manager` | Install cert-manager if missing, then continue |
| `--mcp` | Also pull/load/deploy MCP (`Async-MCP/manifests/async-profiler-mcp-server-kind.yaml`) |
| `--teardown` | Remove Jafra + MCP; remove cert-manager **only if** this script installed it |
| `--uninstall-cert-manager` | With `--teardown`: force-remove cert-manager even if unmarked |

**Env:** `KIND_CLUSTER`, `JAFRA_VERSION`, `MCP_VERSION` (default `0.1.0`), `MCP_IMAGE`.

Default Jafra images: `quay.io/causa-ai-hub/jafra-*:0.1.0`.  
Default MCP image: `quay.io/khansaad/async-profiler-mcp-server:0.1.0`.

**cert-manager ownership:** when `--install-cert-manager` actually installs
cert-manager, the script labels `namespace/cert-manager` with
`jafra.io/installed-by=pull-jafra`. A later `--teardown` uninstalls that
cert-manager automatically. Pre-existing cert-manager is left alone unless you
pass `--teardown --uninstall-cert-manager`.

**MCP after deploy:**

```bash
kubectl -n jafra-system port-forward svc/async-profiler-mcp-server 18081:8080
# Streamable HTTP: http://127.0.0.1:18081/mcp/
```

MCP is configured with
`JAFRA_ANALYZER_URL=http://jafra-analyzer.jafra-system.svc.cluster.local:8080`.

---

## Profile a workload

After install, label/annotate a Java Pod (see `deploy/examples/`):

```yaml
labels:
  jafra.io/enabled: "true"
  jafra.io/mode: "continuous"
annotations:
  jafra.io/containers: "<your-container-name>"
```

Analyzer API:

```bash
kubectl -n jafra-system port-forward svc/jafra-analyzer 8080:8080
curl http://127.0.0.1:8080/api/v1/recordings
```
