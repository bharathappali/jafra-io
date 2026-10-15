# Analyzer API — UX gaps (functional test perspective)

Observations from building `tests/functional/` against
[`jafra-analyzer/docs/api/v1/`](../../jafra-analyzer/docs/api/v1/). These are **product/UX**
notes, not failures of the current contract.

## Discovery and time windows

| Gap | Impact | Possible API change |
|-----|--------|---------------------|
| Default `last=15m` on collect/analytics | Live clusters with **no recent** chunks return 404; Explorer/users think analyzer is broken | `GET /api/v1/workload` detail already exposes `start`/`end` — document that clients **must** derive windows from workload detail or index `ContainerIndex.start/end` |
| No single “data coverage” on index | Index tree has per-container `start`/`end` in `ContainerIndex`, but easy to miss | Add top-level `GET /api/v1/coverage?namespace&pod&container` or include `suggestedFrom`/`suggestedTo` on workload detail |
| Golden September 2026 vs “now” | Docs use fixed dates; production uses wall clock | Optional `GET /api/v1/workload?...&include=windows` returning min/max and last chunk time |

## Event exploration

| Gap | Impact | Possible API change |
|-----|--------|---------------------|
| `event-types` lists types but no field schema | Hard to build UI field pickers for `series` `field=` | `GET /api/v1/event-types/{id}/schema` or `fields[]` on each type |
| `records` without stack decode | “Deep dive” needs multiple calls + client parsing | `view=records&include=stack=true` or dedicated `GET .../stacks/{hash}` |
| Search / filter by thread or class | Users grep JMC; API is type-centric only | Query params on `/events`: `thread`, `classPrefix`, `stackContains` |

## Aggregations and analytics

| Gap | Impact | Possible API change |
|-----|--------|---------------------|
| Two parallel surfaces (`/aggregations/*` vs `/analytics/*`) | Integrators unsure which to use | Short **decision guide** in OpenAPI; optional `GET /api/v1/capabilities` |
| Analytics `subsystem` filter only | No “severity” or “dataQuality=empty hide” | Response already has `dataQuality`; expose filter `minQuality=` |
| No pagination on large `top` lists | `top=30` max may truncate without cursor | `next` token on evidence arrays |

## Bundles and reports

| Gap | Impact | Possible API change |
|-----|--------|---------------------|
| Bundle sections are opaque composed JSON | Clients cannot link “section → underlying URL” | Each section: `{ "source": "/api/v1/aggregations/gc-pauses?...", "body": ... }` |
| Report/summary vs timeseries mental model | `recording=` allowed on one family only | Unified error message + `GET /api/v1/help/recording-param` (machine-readable) |

## Operations and integration

| Gap | Impact | Possible API change |
|-----|--------|---------------------|
| No OpenAPI 3 document served | Functional tests hand-maintain expectations | Ship `/q/openapi` or static `openapi.yaml` in repo |
| Nested URLs return **399** | Surprising for kubectl users | Keep 399 but add `Link` + JSON `canonicalUrl` in body (verify in tests) |
| Workload identity is pod **name** not UID | Pod restarts change series continuity | Optional `workloadId` stable key in ingest + API |

## What already works well

- Workload **detail** `start` / `end` and per-recording bounds (validated in tests).
- Shared **`context`** envelope on analysis responses.
- **Event-types** catalog with topics for navigation.
- **Bundles** catalog matches docs; playbooks compose lower-level APIs.
- **Analytics** `schemaVersion` and fixed subsystem set (testable contract).

## Recommended client flow (today)

1. `GET /api/v1/workload` → pick namespace/pod/container (read `start`/`end`).
2. Use **`from`/`to` from workload detail** for all collect/aggregation/analytics calls.
3. `GET /api/v1/event-types?...&from&to` → pick `types`.
4. `GET /api/v1/events?types=...&view=summary|records|series` for drill-down.
5. Use **`/api/v1/bundles/{id}`** for LLM playbooks; **`/api/v1/analytics/timeseries`** for charts.

No analyzer code changes are **required** for functional testing; gaps above are enhancements for Explorer, MCP, and scripted analysis.
