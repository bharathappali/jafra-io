"""Thin HTTP client for jafra-analyzer v1 API."""

from __future__ import annotations

import json
import os
from dataclasses import dataclass
from typing import Any, Optional
from urllib.parse import urljoin

import requests

# Max characters of response body embedded in HTML report per call.
_MAX_BODY_CHARS = 12_000

from api_expectations import (
    GOLDEN_CONTAINER,
    GOLDEN_FROM,
    GOLDEN_NAMESPACE,
    GOLDEN_POD,
    GOLDEN_TO,
)


@dataclass(frozen=True)
class WorkloadTarget:
    namespace: str
    pod: str
    container: str
    data_start: Optional[str] = None
    data_end: Optional[str] = None


class AnalyzerClient:
    def __init__(self, base_url: str, timeout: float = 120.0) -> None:
        self.base_url = base_url.rstrip("/") + "/"
        self.timeout = timeout
        self.session = requests.Session()
        self.call_log: list[str] = []

    def clear_call_log(self) -> None:
        self.call_log.clear()

    def format_call_log(self) -> str:
        return "\n\n".join(self.call_log)

    def get(self, path: str, **params: Any) -> requests.Response:
        url = urljoin(self.base_url, path.lstrip("/"))
        return self.session.get(url, params=params or None, timeout=self.timeout)

    def json(self, path: str, **params: Any) -> tuple[int, Any]:
        filtered = {k: v for k, v in params.items() if v is not None and v != ""}
        response = self.get(path, **filtered)
        try:
            body = response.json()
        except ValueError:
            body = response.text
        self._record_call(response, filtered, body)
        return response.status_code, body

    def _record_call(
        self,
        response: requests.Response,
        query_params: dict[str, Any],
        body: Any,
    ) -> None:
        req = response.request
        method = (req.method or "GET").upper() if req else "GET"
        url = response.url or req.url if req else ""
        query_line = ""
        if query_params:
            query_line = f"\n    query: {json.dumps(query_params, sort_keys=True)}"
        entry = (
            f">>> {method} {url}{query_line}\n"
            f"<<< HTTP {response.status_code} {response.headers.get('Content-Type', '')}\n"
            f"{self._format_body(body)}"
        )
        self.call_log.append(entry)

    @staticmethod
    def _format_body(body: Any) -> str:
        if isinstance(body, (dict, list)):
            text = json.dumps(body, indent=2, sort_keys=True, default=str)
        else:
            text = str(body)
        if len(text) > _MAX_BODY_CHARS:
            return text[:_MAX_BODY_CHARS] + f"\n... ({len(text) - _MAX_BODY_CHARS} chars truncated)"
        return text

    def discover_workload(
        self,
        namespace: Optional[str] = None,
        pod: Optional[str] = None,
        container: Optional[str] = None,
    ) -> WorkloadTarget:
        if namespace and pod and container:
            status, body = self.json(
                "/api/v1/workload",
                namespace=namespace,
                pod=pod,
                container=container,
            )
            if status == 200 and isinstance(body, dict):
                return WorkloadTarget(
                    namespace=namespace,
                    pod=pod,
                    container=container,
                    data_start=body.get("start"),
                    data_end=body.get("end"),
                )
            return WorkloadTarget(namespace, pod, container)

        status, body = self.json("/api/v1/workload")
        if status != 200:
            raise RuntimeError(f"GET /api/v1/workload failed: HTTP {status} {body!r}")

        picked = _pick_from_discovery(body)
        if picked:
            return picked

        # No ingested data — allow golden identity for CI/dev with fixture chunks.
        return WorkloadTarget(
            GOLDEN_NAMESPACE,
            GOLDEN_POD,
            GOLDEN_CONTAINER,
            GOLDEN_FROM,
            GOLDEN_TO,
        )


def _pick_from_discovery(body: dict[str, Any]) -> Optional[WorkloadTarget]:
    if body.get("namespace") and body.get("pod") and body.get("container"):
        if body.get("recordingCount", 0) > 0 or body.get("chunkCount", 0) > 0:
            return WorkloadTarget(
                body["namespace"],
                body["pod"],
                body["container"],
                body.get("start"),
                body.get("end"),
            )

    workloads = body.get("workloads")
    if isinstance(workloads, list) and workloads:
        w = workloads[0]
        return WorkloadTarget(
            w["namespace"],
            w["pod"],
            w["container"],
            w.get("start"),
            w.get("end"),
        )

    namespaces = body.get("namespaces")
    if isinstance(namespaces, dict):
        for ns, ns_doc in namespaces.items():
            pods = (ns_doc or {}).get("pods") or {}
            for pod_name, pod_doc in pods.items():
                containers = (pod_doc or {}).get("containers") or {}
                for container_name, idx in containers.items():
                    if not isinstance(idx, dict):
                        continue
                    if idx.get("chunkCount", 0) > 0 or idx.get("recordingCount", 0) > 0:
                        return WorkloadTarget(
                            ns,
                            pod_name,
                            container_name,
                            idx.get("start"),
                            idx.get("end"),
                        )
    return None


def client_from_env() -> AnalyzerClient:
    base = os.environ.get("JAFRA_ANALYZER_URL", "http://127.0.0.1:8080")
    return AnalyzerClient(base)


def workload_from_env(client: AnalyzerClient) -> WorkloadTarget:
    ns = os.environ.get("JAFRA_NAMESPACE")
    pod = os.environ.get("JAFRA_POD")
    container = os.environ.get("JAFRA_CONTAINER")
    return client.discover_workload(ns, pod, container)


def analysis_window(target: WorkloadTarget) -> tuple[str, str]:
    if target.data_start and target.data_end:
        return target.data_start, target.data_end
    return GOLDEN_FROM, GOLDEN_TO


def identity_params(target: WorkloadTarget) -> dict[str, str]:
    return {
        "namespace": target.namespace,
        "pod": target.pod,
        "container": target.container,
    }


def window_params(frm: str, to: str) -> dict[str, str]:
    return {"from": frm, "to": to}
