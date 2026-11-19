# Request performance

[Documentation](readme.md) · [Testing](testing.md)

Measure client latency and application execution separately. A browser's request
time includes connection establishment, network round trips, API Gateway, Lambda,
and response transfer. Lambda's REPORT duration and the application profile cover
different portions of that path.

## Public HTTP measurements

From the checkout, with Python 3 and curl 7.84 or newer:

```sh
python3 bin/measure-http.py --samples 5 --output /tmp/ttrek-http.json
# Or point at the local stack:
python3 bin/measure-http.py --base-url http://127.0.0.1:8080
```

This sends sequential anonymous GETs to Home, Forum, Packages, Docs, and Blog,
requesting compression. It starts a fresh curl process for each page, then reuses
connections for that page's repeats where the server permits it. Transfers are
limited to two starts per second. Redirects, HTTP errors and transport errors are
reported rather than silently retried. A non-200 response makes the script fail.
The default is 30 total requests. Cookies are not supplied or persisted.

The first transfer is shown separately; it is **not evidence of a Lambda cold
start**. Repeats can also reach different Lambda workers. `Wait` is TTFB minus
curl's pretransfer time, so it still includes network transit, gateway overhead,
and Lambda. The JSON output retains curl's DNS, TCP, TLS, transfer, status and
connection-reuse fields. Compare the same client location and authentication
state. A logged-in browser can perform additional session and authorization work.

Baseline on November 18, 2026, before deploying the instrumentation, from the
development machine against `https://ttrek.sh`, with five repeats per page:

| Page | First TTFB | Repeat TTFB median | Repeat TTFB p95 | Repeat total median |
| --- | ---: | ---: | ---: | ---: |
| Home | 580.9 ms | 184.7 ms | 200.5 ms | 184.9 ms |
| Forum | 254.3 ms | 124.4 ms | 150.4 ms | 124.7 ms |
| Packages | 528.6 ms | 397.7 ms | 413.6 ms | 398.3 ms |
| Docs | 263.0 ms | 121.3 ms | 418.1 ms | 121.6 ms |
| Blog | 254.2 ms | 118.4 ms | 129.0 ms | 118.5 ms |

All responses were 200. With five repeats, nearest-rank p95 is the maximum;
these are diagnostic samples, not production latency estimates. Packages was
consistently slower in this sample. AWS CLI credentials were invalid, so deployed
version, live memory configuration and Lambda REPORT durations were not verified.
The checked-in SAM template configures 256 MB.

## Application profiles

Request profiling is off by default. CodeBuild deploys with `RequestProfiling=0`.
For a diagnostic Lambda deployment, pass `RequestProfiling=1` and point the
public `DEFAULT` alias at the new version. To profile a local run:

```sh
TTREK_PROFILE=1 ./run.sh
```

With profiling enabled, each invocation emits one JSON record to stderr with `event: site_profile`.
Direct HTTP requests emit one too; the Lambda adapter shares the inner dispatch
profile and emits only after response JSON encoding. Private maintenance events
and invalid Lambda envelopes can also produce records, with route `unmatched`
and status zero when no HTTP response was produced. Fields include:

- `request_id`: Lambda invocation ID, for correlation with START/END/REPORT.
- `route`: static site route name or package dispatch command; never a URL.
- `sequence` and `first_request`: invocation order in this interpreter while
  profiling is enabled. Use REPORT `Init Duration` to establish a cold start;
  the first visit to another feature can still trigger lazy loading later.
- `duration_ms`: wall time from adapter entry through the completed response,
  including trace setup, excluding profile serialization/logging and the runtime's
  response submission. Initialization is logged separately as `site_init`.
- `status`, `completion_code`, `memory_mb`, `version`, and `loading` when available.
- `timings`: each observed category's `calls`, `total_ms`, and `self_ms`.

`total_ms` includes nested traced calls. **Do not sum inclusive times.**
`self_ms` subtracts nested traced calls, including recursion, and helps locate
unexplained work. Both measure elapsed wall time, including I/O waits; neither
measures CPU directly. Trace bookkeeping adds overhead, especially during lazy
loading, so compare with profiling disabled after identifying the expensive work.

| Category | What it covers |
| --- | --- |
| `dispatch` | Complete site dispatch, including routing and final response preparation |
| `middleware_init`, `package`, `source`, `service` | Lazy code loading and resource preparation |
| `monitor_enter`, `monitor_leave`, `monitor_store`, `monitor_recent` | Request collection and Valkey writes |
| `authentication`, `authorization`, `navigation` | Account middleware and final HTML navigation |
| `rate_limit`, `route_rate_limit`, `sensitive_route`, `rate_limit_store` | Global/route checks and their Valkey calls |
| `handler` | Site handler or package preparation and dispatch |
| `database`, `sql_connect` | Connection acquisition and first SQL connection |
| `sql_execute`, `sql_foreach`, `sql_raw` | SQL adapter work, including compilation, network waits and row conversion; foreach includes its row callbacks |
| `catalog_read`, `catalog_group`, `catalog_cards` | Packages catalog retrieval, grouping and card data construction |
| `tracker`, `tracker_cache`, `homepage` | Tracker snapshot, cache access and homepage data assembly |
| `template` | Site/package template rendering, including context encoding and first-use template loading |
| `response_prepare` | Response byte conversion, gzip, validators and HEAD suppression |
| `json_decode`, `json_encode` | JSON conversion at observed application boundaries |

The existing tpathexp middleware registration and ordering are unchanged.
Execution traces observe selected commands, including dependencies loaded during
the request; they are removed at completion, including on errors. No request
headers, cookies, bodies, query strings, SQL text, parameters or error messages
are written by the profiler. Timings are not exposed in public response headers.

Example CloudWatch Logs Insights query for a short diagnostic window:

```text
filter event = "site_profile" and status = 200
| stats count(*) as requests,
    pct(duration_ms, 50) as app_p50,
    pct(duration_ms, 95) as app_p95,
    avg(timings.sql_execute.total_ms) as sql_ms,
    avg(timings.template.total_ms) as template_ms,
    avg(timings.monitor_leave.total_ms) as monitor_ms,
    avg(timings.response_prepare.total_ms) as response_ms
  by route, first_request, memory_mb, version
```

Missing categories mean the command was not observed, not a measured zero. For a
slow request, compare its JSON record with the REPORT for the same request ID.
The difference includes runtime work and profile output overhead. Compare the
client TTFB with Lambda duration to investigate time outside the application,
allowing for connection setup and network transit. Record cold initialization,
first use of each feature and repeated requests separately.

Once a breakdown is available, compare the same artifact and workload at 256,
512 and 1024 MB, keeping loading mode fixed and comparing billed GB-seconds as
well as latency. AWS allocates CPU in proportion to configured memory; 1,769 MB
corresponds to one vCPU's compute entitlement. Low memory usage alone therefore
does not establish that 256 MB is sufficient.
See [AWS Lambda memory configuration](https://docs.aws.amazon.com/lambda/latest/dg/configuration-memory.html).
No memory change or deployment is performed by the measurement script.

Set `RequestProfiling=0` when profiling is no longer needed.

## Validation

```sh
ttrek run tclsh9.1 tests/profile.test
```

Tests cover default-enabled and explicitly disabled behavior, byte-identical responses, Lambda serialization,
lazy dependency tracing, nested timing, caller-scope semantics, request isolation,
middleware rejection, exception cleanup, log failures and omission of private
values. The suite runs in CodeBuild before packaging. The existing
`tests/static-content.test` can also run with `TTREK_PROFILE=1` to exercise real
rendering, SQL and response policies with isolated fixtures.
