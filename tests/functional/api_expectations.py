"""Constants aligned with jafra-analyzer/docs/api/v1/."""

from __future__ import annotations

AGGREGATION_KINDS = frozenset(
    {"gc-pauses", "trends", "allocations", "samples", "contention", "exceptions"}
)

BUNDLE_IDS = frozenset(
    {
        "version-check",
        "memory",
        "gc",
        "threads",
        "performance",
        "jvm-config",
        "exceptions",
        "diagnostics",
        "proactive",
    }
)

ANALYTICS_SUBSYSTEMS = frozenset(
    {
        "context",
        "cpu",
        "wall_time",
        "threads",
        "heap",
        "allocations",
        "gc",
        "locks",
        "jit",
        "io",
        "container",
        "native_memory",
        "exceptions",
        "vm_internal",
    }
)

CONTEXT_ENVELOPE_KEYS = frozenset(
    {"start", "end", "from", "to", "bytes", "chunks", "recordings", "generatedAt"}
)

WORKLOAD_DETAIL_KEYS = frozenset(
    {
        "namespace",
        "pod",
        "container",
        "recordingCount",
        "chunkCount",
        "start",
        "end",
        "recordings",
    }
)

RECORDING_ENTRY_KEYS = frozenset(
    {"filename", "sequence", "bytes", "chunks", "start", "end", "reportUrl"}
)

EVENT_TYPE_KEYS = frozenset({"id", "name", "topic", "count"})

# Golden fixture windows (docs/api/v1/README.md) — used when live workload has no range.
GOLDEN_NAMESPACE = "default"
GOLDEN_POD = "auth-cache-84cd9fbc49-fttcq"
GOLDEN_CONTAINER = "auth-cache"
GOLDEN_FROM = "2026-09-12T00:00:00Z"
GOLDEN_TO = "2026-09-14T00:00:00Z"
GOLDEN_PROFILER_FROM = "2026-09-12T22:50:54Z"
GOLDEN_PROFILER_TO = "2026-09-12T22:51:00Z"
GOLDEN_JDK_FROM = "2026-09-12T22:50:54Z"
GOLDEN_JDK_TO = "2026-09-12T22:51:54Z"
