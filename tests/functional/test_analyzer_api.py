"""
Functional checks for jafra-analyzer HTTP API v1.

Docs: jafra-analyzer/docs/api/v1/

Run (with port-forward):
  kubectl -n jafra-system port-forward svc/jafra-analyzer 8080:8080
  cd tests/functional && pip install -r requirements.txt && pytest -v

Environment:
  JAFRA_ANALYZER_URL   default http://127.0.0.1:8080
  JAFRA_NAMESPACE/POD/CONTAINER  optional workload override
"""

from __future__ import annotations

import pytest

from analyzer_client import identity_params, window_params
from api_expectations import (
    AGGREGATION_KINDS,
    ANALYTICS_SUBSYSTEMS,
    BUNDLE_IDS,
    EVENT_TYPE_KEYS,
    GOLDEN_JDK_FROM,
    GOLDEN_JDK_TO,
    GOLDEN_PROFILER_FROM,
    GOLDEN_PROFILER_TO,
    RECORDING_ENTRY_KEYS,
    WORKLOAD_DETAIL_KEYS,
)
from validators import (
    assert_context_envelope,
    assert_iso_timestamp,
    assert_keys_present,
    assert_start_before_end,
)


class TestOperational:
    def test_health(self, client):
        status, body = client.json("/health")
        assert status == 200
        assert body.get("status") == "UP"

    def test_status(self, client):
        status, body = client.json("/api/v1/status")
        assert status == 200
        assert "durableChunks" in body


class TestWorkloadAndRecordings:
    def test_workload_index_lists_data(self, client, target):
        status, body = client.json("/api/v1/workload")
        assert status == 200
        assert isinstance(body, dict)
        # Tree or flat list depending on corpus size.
        has_tree = "namespaces" in body or "workloads" in body
        has_detail = body.get("namespace") == target.namespace
        assert has_tree or has_detail or body.get("recordingCount", 0) >= 0

    def test_workload_detail_timestamps(self, client, target):
        status, body = client.json("/api/v1/workload", **identity_params(target))
        if status == 404:
            pytest.skip("no workload data ingested yet")
        assert status == 200
        assert_keys_present(body, WORKLOAD_DETAIL_KEYS, "workload detail")
        assert body["recordingCount"] >= 0
        assert body["chunkCount"] >= 0
        if body.get("start") and body.get("end"):
            assert_iso_timestamp("workload.start", body["start"])
            assert_iso_timestamp("workload.end", body["end"])
            assert_start_before_end(body["start"], body["end"], "workload")

    def test_workload_recordings_have_time_bounds(self, client, target):
        status, body = client.json("/api/v1/workload", **identity_params(target))
        if status == 404:
            pytest.skip("no workload data")
        assert status == 200
        recordings = body.get("recordings") or []
        if not recordings:
            pytest.skip("workload has no closed recordings yet")
        for rec in recordings[:5]:
            assert_keys_present(rec, RECORDING_ENTRY_KEYS, "recording")
            if rec.get("start") and rec.get("end"):
                assert_start_before_end(rec["start"], rec["end"], rec["filename"])

    def test_recordings_list(self, client, target):
        # See docs/api/v1/samples/recordings-list.json — top-level workloads[], not recordings[].
        status, body = client.json(
            "/api/v1/recordings",
            **identity_params(target),
        )
        if status == 404:
            pytest.skip("no recordings for workload")
        assert status == 200
        assert isinstance(body.get("workloads"), list)
        if not body["workloads"]:
            pytest.skip("recordings list empty")
        match = next(
            (
                w
                for w in body["workloads"]
                if w.get("namespace") == target.namespace
                and w.get("pod") == target.pod
                and w.get("container") == target.container
            ),
            None,
        )
        if match is None:
            pytest.skip("target workload not present in recordings response")
        recordings = match.get("recordings") or []
        assert len(recordings) >= 1
        for rec in recordings[:5]:
            assert_keys_present(rec, RECORDING_ENTRY_KEYS, "recording")
            if rec.get("start") and rec.get("end"):
                assert_start_before_end(rec["start"], rec["end"], rec["filename"])


class TestCollectAndEvents:
    def test_event_types_catalog(self, client, target, window):
        frm, to = window
        status, body = client.json(
            "/api/v1/event-types",
            **identity_params(target),
            **window_params(frm, to),
        )
        if status == 404:
            pytest.skip("no chunks overlap window (try widening from/to or ingest data)")
        assert status == 200
        assert "types" in body
        assert isinstance(body["types"], list)
        assert len(body["types"]) > 0
        if "context" in body:
            assert_context_envelope(body["context"])
        sample = body["types"][0]
        assert_keys_present(sample, EVENT_TYPE_KEYS, "event type")

    def test_events_summary_and_records_deep_dive(self, client, target, window):
        frm, to = window
        _, types_doc = client.json(
            "/api/v1/event-types",
            **identity_params(target),
            **window_params(frm, to),
        )
        if not isinstance(types_doc, dict) or not types_doc.get("types"):
            pytest.skip("no event types")
        type_id = types_doc["types"][0]["id"]

        status, summary = client.json(
            "/api/v1/events",
            **identity_params(target),
            types=type_id,
            view="summary",
            **window_params(frm, to),
        )
        if status == 404:
            pytest.skip("events window empty")
        assert status == 200
        assert summary.get("view") == "summary"
        assert "summaries" in summary or "summary" in summary

        status, records = client.json(
            "/api/v1/events",
            **identity_params(target),
            types=type_id,
            view="records",
            limit=5,
            **window_params(GOLDEN_PROFILER_FROM, GOLDEN_PROFILER_TO),
        )
        if status == 404:
            # Fall back to full corpus window for live clusters.
            status, records = client.json(
                "/api/v1/events",
                **identity_params(target),
                types=type_id,
                view="records",
                limit=5,
                **window_params(frm, to),
            )
        if status == 404:
            pytest.skip("no records for type in window")
        assert status == 200
        assert records.get("view") == "records"

    def test_events_series_cpu_load(self, client, target):
        status, body = client.json(
            "/api/v1/events",
            **identity_params(target),
            types="jdk.CPULoad",
            view="series",
            field="machineTotal",
            limit=10,
            **window_params(GOLDEN_JDK_FROM, GOLDEN_JDK_TO),
        )
        if status == 404:
            status, body = client.json(
                "/api/v1/events",
                **identity_params(target),
                types="jdk.CPULoad",
                view="series",
                field="machineTotal",
                limit=10,
                **window_params(GOLDEN_PROFILER_FROM, GOLDEN_PROFILER_TO),
            )
        if status == 404:
            pytest.skip("jdk.CPULoad not in corpus/window")
        assert status == 200
        assert body.get("view") == "series"
        assert body.get("field") == "machineTotal"
        series = body.get("series") or {}
        assert "jdk.CPULoad" in series
        points = series["jdk.CPULoad"]
        assert isinstance(points, list)
        if points:
            assert "timeNs" in points[0] and "value" in points[0]

    def test_recording_param_rejected_on_collect(self, client, target):
        status, body = client.json(
            "/api/v1/event-types",
            **identity_params(target),
            recording="profile-1.jfr",
            last="5m",
        )
        assert status == 400
        assert body.get("status") == "bad_request"


class TestAggregations:
    @pytest.mark.parametrize("kind", sorted(AGGREGATION_KINDS))
    def test_aggregation_kind(self, client, target, window, kind):
        frm, to = window
        status, body = client.json(
            f"/api/v1/aggregations/{kind}",
            **identity_params(target),
            **window_params(frm, to),
            limit=5,
        )
        if status == 404:
            pytest.skip(f"{kind}: no data in window")
        assert status == 200
        assert body.get("kind") == kind
        assert "stats" in body or "top" in body or "trends" in body
        if "context" in body:
            assert_context_envelope(body["context"])

    def test_samples_wall_flavor_slice(self, client, target):
        status, body = client.json(
            "/api/v1/aggregations/samples",
            **identity_params(target),
            flavor="wall",
            limit=3,
            **window_params(GOLDEN_PROFILER_FROM, GOLDEN_PROFILER_TO),
        )
        if status == 404:
            pytest.skip("profiler wall samples not in window")
        assert status == 200
        assert body.get("kind") == "samples"


class TestAnalytics:
    def test_timeseries_schema(self, client, target):
        status, body = client.json(
            "/api/v1/analytics/timeseries",
            **identity_params(target),
            **window_params(GOLDEN_PROFILER_FROM, GOLDEN_PROFILER_TO),
            subsystem="cpu,wall_time,allocations",
            top=5,
        )
        if status == 404:
            status, body = client.json(
                "/api/v1/analytics/timeseries",
                **identity_params(target),
                **window_params(GOLDEN_JDK_FROM, GOLDEN_JDK_TO),
                subsystem="container,heap,gc,cpu",
                top=5,
            )
        if status == 404:
            pytest.skip("analytics timeseries: no overlapping chunks")
        assert status == 200
        assert body.get("schemaVersion") == 1
        assert body.get("mode") == "timeseries"
        subs = body.get("subsystems") or {}
        assert isinstance(subs, dict)
        assert len(subs) >= 1
        for key in subs:
            assert key in ANALYTICS_SUBSYSTEMS

    def test_daily_stats(self, client, target, window):
        frm, to = window
        status, body = client.json(
            "/api/v1/analytics/daily_stats",
            **identity_params(target),
            **window_params(frm, to),
            top=5,
        )
        if status == 404:
            pytest.skip("daily_stats: no data")
        assert status == 200
        assert body.get("mode") == "daily_stats"


class TestBundles:
    def test_bundle_catalog(self, client):
        status, body = client.json("/api/v1/bundles")
        assert status == 200
        bundles = body.get("bundles") or []
        ids = {b["id"] for b in bundles}
        assert ids == BUNDLE_IDS

    @pytest.mark.parametrize("bundle_id", sorted(BUNDLE_IDS))
    def test_bundle_playbook(self, client, target, window, bundle_id):
        frm, to = window
        status, body = client.json(
            f"/api/v1/bundles/{bundle_id}",
            **identity_params(target),
            **window_params(frm, to),
            limit=5,
        )
        if status == 404:
            pytest.skip(f"bundle {bundle_id}: no data")
        assert status == 200
        assert body.get("id") == bundle_id
        assert "sections" in body
        assert isinstance(body["sections"], dict)
        ctx = body.get("context") or {}
        if ctx:
            for key in ("chunks", "recordings"):
                if key in ctx:
                    assert ctx[key] is not None


class TestReportSummary:
    def test_summary_latest_or_window(self, client, target, window):
        frm, to = window
        status, body = client.json(
            "/api/v1/summary",
            **identity_params(target),
            **window_params(frm, to),
        )
        if status == 404:
            pytest.skip("summary unavailable")
        assert status == 200
        assert "context" in body or "events" in body or "summary" in body


def pytest_configure(config):
    config.addinivalue_line(
        "markers",
        "live: requires analyzer with ingested JFR (may skip when empty)",
    )
