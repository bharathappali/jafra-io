"""JSON shape helpers for analyzer API responses."""

from __future__ import annotations

from datetime import datetime, timezone
from typing import Any, Iterable


def parse_utc_iso(value: str) -> datetime:
    if not value or not isinstance(value, str):
        raise ValueError(f"expected ISO-8601 string, got {value!r}")
    normalized = value.replace("Z", "+00:00")
    dt = datetime.fromisoformat(normalized)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)


def assert_iso_timestamp(field: str, value: Any) -> datetime:
    try:
        return parse_utc_iso(value)
    except ValueError as exc:
        raise AssertionError(f"{field}: {exc}") from exc


def assert_keys_present(obj: dict[str, Any], required: Iterable[str], label: str) -> None:
    missing = [k for k in required if k not in obj]
    if missing:
        raise AssertionError(f"{label} missing keys: {missing}")


def assert_start_before_end(start: str, end: str, label: str = "range") -> None:
    s = parse_utc_iso(start)
    e = parse_utc_iso(end)
    if s > e:
        raise AssertionError(f"{label}: start {start} is after end {end}")


def assert_context_envelope(ctx: dict[str, Any], *, require_window: bool = True) -> None:
    assert isinstance(ctx, dict), "context must be an object"
    if require_window:
        for key in ("start", "end"):
            if key in ctx and ctx[key] is not None:
                assert_iso_timestamp(f"context.{key}", ctx[key])
        if ctx.get("start") and ctx.get("end"):
            assert_start_before_end(ctx["start"], ctx["end"], "context")
