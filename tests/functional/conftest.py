import html as html_module
import sys
from pathlib import Path

# Allow imports without installing a package.
_ROOT = Path(__file__).resolve().parent
if str(_ROOT) not in sys.path:
    sys.path.insert(0, str(_ROOT))

import pytest
import requests

from analyzer_client import AnalyzerClient, analysis_window, client_from_env, workload_from_env


def pytest_sessionstart(session):
    base = client_from_env().base_url.rstrip("/")
    try:
        requests.get(f"{base}/health", timeout=3)
    except requests.RequestException as exc:
        pytest.exit(
            f"jafra-analyzer not reachable at {base} ({exc}). "
            "Start port-forward: kubectl -n jafra-system port-forward svc/jafra-analyzer 8080:8080",
            returncode=0,
        )


@pytest.fixture(scope="session")
def client() -> AnalyzerClient:
    return client_from_env()


@pytest.fixture(autouse=True)
def _reset_api_call_log(client: AnalyzerClient):
    """Each test gets a fresh API I/O trace for the HTML report."""
    client.clear_call_log()
    yield


@pytest.hookimpl(hookwrapper=True)
def pytest_runtest_makereport(item, call):
    outcome = yield
    report = outcome.get_result()
    if call.when != "call":
        return
    client = item.funcargs.get("client")
    if not client or not client.call_log:
        return
    html_plugin = item.config.pluginmanager.getplugin("html")
    if html_plugin is None:
        return
    from pytest_html import extras

    text = client.format_call_log()
    # pytest-html 3.2: extras.text() → Links column only; extras.html() → expanded detail row.
    block = html_module.escape(text)
    payload = extras.html(f'<div class="log"><strong>API I/O</strong>\n{block}</div>')
    if getattr(report, "extra", None) is None:
        report.extra = []
    report.extra.append(payload)


@pytest.fixture(scope="session")
def target(client: AnalyzerClient):
    return workload_from_env(client)


@pytest.fixture(scope="session")
def window(target):
    return analysis_window(target)
