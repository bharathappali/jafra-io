# Jafra ingest contract

Canonical protobuf for `jafra-agent` and `jafra-analyzer` lives in
`contracts/jafra.proto`. Both components generate language bindings from this
file at build time. Do not hand-edit generated sources.

Protocol version `1` is the only accepted `OpenChunk.protocol_version`.
Unknown protobuf fields are ignored by proto3, so later optional metadata can
be added without breaking current clients.

## Build-time generation

- Rust: `jafra-agent/build.rs` compiles the proto with `tonic-build`.
- Java: `jafra-analyzer` copies this file into `src/main/proto` during Maven
  `initialize`, then Quarkus gRPC generates stubs.

## Identity

Chunk identity is SHA-256 of:

```text
cluster_id|pod_uid|container|filename|offset|length
```

The payload checksum is a second SHA-256 of the streamed bytes.
