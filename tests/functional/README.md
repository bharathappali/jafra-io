# Jafra analyzer — functional API tests

Python checks against a **live** `jafra-analyzer` (typically port-forwarded). Assertions follow
[`jafra-analyzer/docs/api/v1/`](../../jafra-analyzer/docs/api/v1/README.md).

## Prerequisites

1. Analyzer running and reachable (Kind, OpenShift, or local Quarkus dev).
2. **Ingested JFR** for at least one workload (e.g. deploy `deploy/examples/auth-cache.yaml`
   and wait for chunk rotation), **or** dev corpus under analyzer storage.

## Quick start

```bash
kubectl -n jafra-system port-forward svc/jafra-analyzer 8080:8080
```

```bash
cd tests/functional
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
pytest -v --html=report.html --self-contained-html
```

Each test row includes **API I/O** in the expanded detail (gray log panel): request URL,
query params, response status, and JSON body (truncated at 12k chars per call). Click the
row to expand if needed (`render_collapsed = false` in `pytest.ini` keeps rows open by default).

Default base URL: `http://127.0.0.1:8080` (`JAFRA_ANALYZER_URL`).

### Target a specific workload

```bash
export JAFRA_NAMESPACE=default
export JAFRA_POD=auth-cache-xxxxxxxx-xxxxx
export JAFRA_CONTAINER=auth-cache
pytest -v
```

If unset, tests call `GET /api/v1/workload`, pick the first container with chunks, and use its
`start` / `end` for time-windowed APIs. If nothing is ingested, tests fall back to **golden
fixture** identities from the API docs (many calls will **skip** with 404 until data exists).

## What is covered

| Area | Checks |
|------|--------|
| Operational | `/health`, `/api/v1/status` |
| Workload | Detail `start`/`end`, per-recording bounds, `/recordings` |
| Collect | `/event-types`, `/events` summary + records + series |
| Aggregations | All six `kind` values |
| Analytics | `timeseries` + `daily_stats` envelope |
| Bundles | Catalog ids + each playbook `sections` |
| Summary | `/api/v1/summary` with corpus window |

## UX / API gaps

See [API_UX_GAPS.md](API_UX_GAPS.md) for suggested analyzer improvements discovered while
mapping these tests.

## Regenerate golden JSON (analyzer submodule)

```bash
cd jafra-analyzer
mvn -Dtest=ApiDocumentationSampleGeneratorTest test
```
