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
```

## Clone

```bash
git clone --recurse-submodules https://github.com/bharathappali/jafra-io.git
```

If the parent is already cloned:

```bash
git submodule update --init --recursive
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

Build component images from this root so Dockerfiles can see `contracts/`
and `deploy/`. Images are published as `quay.io/bharathappali/jafra-*:0.1.0`.
