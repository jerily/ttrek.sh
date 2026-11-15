# Package Tracker

[Documentation](readme.md) · [Package registry](registry.md)

`/packages/tracker` shows up to **5 packages per measure**. `/package-tracker`
redirects there. `/packages` includes a rotating summary with three packages on
wide screens, two on intermediate screens and one on mobile. Individual package
overviews show recipe download activity and daily charts once a package has
downloads from at least 10 unique machines across three active UTC days.

## Measures

- **New:** first public registry inclusion during the last 30 days, newest first.
- **Recently Updated:** a previously published package gains a registry version
  during the last 30 days. One entry per package, ordered by publication date;
  simultaneous versions prefer the higher version. Recipe edits and withdrawal
  followed by republication of the same version do not count.
- **Popular:** unique machines downloading recipes in the last 30 days, descending.
- **Trending:** unique machines in the last 7 days compared with the preceding
  7 days, ordered by percentage growth, then absolute increase, then name.
  Defaults require 10 recent machines, 5 baseline machines, an increase of 5
  machines and 25%. Multiple registrations of the same machine hash count once.
  Zero baselines never produce infinite percentages. At least 14 days of recipe-request history
  must exist before comparisons are shown.

Periods are half-open rolling intervals `[start, cutoff)` sharing a refresh
cutoff. The existing `req_reg_get_pkg_spec` events join `environments` to deduplicate
machine hashes separately for each window, across versions, platforms and repeat
requests. Requests for dependencies count. Only currently listed versions contribute;
installation events, page views, telemetry-only packages and withdrawn versions do not.
Requests without a registered machine ID are excluded from unique counts. These
counts establish neither unique people nor successful installations. Machine
identifiers never appear in the public snapshot.

UTC daily buckets cover the same 30-day interval; endpoint buckets may be partial
and are labeled. Each bucket counts distinct machines within that day; a returning
machine can appear on multiple days. The 30-day total is deduplicated independently,
not summed from daily counts. Days before the earliest stored recipe-request event
are shown as unavailable. History cannot establish whether clients always supplied
IDs or collection had interruptions.

All-time recipe download totals by OS/architecture come from
`package_download_counts`, one cumulative counter per version/platform. These include
anonymous requests and repeats; they remain separate from installation outcomes.
Initialization seeds missing counters from existing published-package request history
without resetting existing counters. Historical events were recorded before response
validation; new requests count only after a valid recipe response is prepared, and
`latest` resolves to the actual version. This measures served recipes, not completed
archive downloads. No new download event type is introduced. Existing identified
events support unique rankings; anonymous requests only increment counters.
Both platform tables include withdrawn versions and survive registry synchronization.

Optional `[package_tracker]` INI overrides are positive integers:

```ini
[package_tracker]
min_current=10
min_previous=5
min_delta=5
min_growth=25
```

The methodology panel describes the thresholds stored with the snapshot, so a
configuration change does not mislabel a previously generated ranking.

## Publication dates

`package_names.first_published_at` records first inclusion; `packages.published_at`
records each version's first publication. Zero means unpublished. Successful
registry sync records epoch seconds in the same transaction as the catalog.
Telemetry insertion never sets publication dates. Dates survive metadata edits,
withdrawal, republication, and repeated synchronization.

The additive migration initializes missing dates on **already listed** versions
to **November 15, 2026 (UTC)**, as an explicit initial estimate. Corresponding
package dates use their earliest published version. These dates are stored
directly in `first_published_at` and `published_at`, without separate estimate
flags. Filesystem timestamps are deliberately unused: checkout and archive
operations rewrite them.
`publication_is_update` distinguishes later releases from all versions in a
package's initial publication batch. Initial estimated versions are not treated
as updates. New versions published after initialization get their actual sync
time.

Backfills must update both package and version dates consistently using
authoritative evidence. Refresh the tracker afterward.

## Refresh and storage

`tcl/package-tracker.tcl` aggregates the package and telemetry tables through
`tpersist`. PostgreSQL uses a read-only repeatable-read transaction with 20-second
statement limits; LOCAL uses SQLite. A time/package/environment index bounds the
30-day activity scan. HTTP handlers never run aggregation.

The private Lambda event is:

```json
{"source":"ttrek.patch","task":"task_refresh_package_tracker"}
```

`SiteFunctionPackageTracker` in `devops/sam-template.yaml` invokes the existing
website Lambda every five minutes using its existing scheduler IAM role. It is
not an HTTP route and uses the existing database and `[redis]` configuration.

A 240-second Valkey lease prevents overlapping refreshes. An ownership token
prevents an expired worker from publishing. A complete staged hash contains
metadata, four rankings, and per-package chart data; atomic `RENAME` publishes
it under `ttrek:package-tracker:v2:active`. The new namespace and format prevent
installation-based snapshots from appearing under download labels. Readers use `HMGET` to obtain fields
from one generation. Snapshots expire after 24 hours; readers flag refreshes
older than 15 minutes as delayed. Failed jobs retain the previous snapshot.
Missing, corrupt or inaccessible cache data is unavailable, not zero activity.
Current catalog metadata filters withdrawn links at rendering time.
The `/packages` summary appears only when a valid cached snapshot contains
visible entries. Package overviews show their activity panel only when their
cached statistics are available. The tracker page itself remains accessible
and explains when activity data is unavailable.

Valkey is derived storage and is rebuilt after a restore or cache loss. After
restoring an older database, initialize the schema and refresh to replace the
previous cached results. Local and production environments must use separate
Valkey instances, as with the existing monitor and rate limiter.

## Local commands

With local Lambda and Valkey running, and after packaging the changed website:

```sh
ttrek run -script bootstrap-local
```

Bootstrap runs `initdb-local`, `sync-local`, and `refresh-package-tracker-local`
in order, stopping at the first failure. Each command also remains available
individually. Use `-- --lambda-port PORT` to select a different local Lambda port
for all three steps.

The refresh command uses `bin/invoke-patch-local.sh`, validates task completion,
and returns `refreshed` or `skipped` when another task holds the lease. It accepts
the same `--lambda-port` override as the other local patch commands:

```sh
ttrek run -script refresh-package-tracker-local -- --lambda-port 3101
```

Account pruning uses the same mechanism:

```sh
ttrek run -script prune-accounts-local
```

The existing `prune-accounts` command remains an alias. These commands target
the local Lambda; they do not invoke AWS.

All private patch tasks emit structured `patch_task_start` and `patch_task_end`
logs with task name and UTC timestamp. End logs include `status` (`ok` or `error`)
and `duration_ms`, even when a task throws. Error bodies, connection arguments,
and telemetry rows are not included in lifecycle logs.

## Deployment

1. Deploy the code and scheduler; the five-minute schedule is enabled by default.
2. Invoke `task_initdb_website` to add fields, indexes and estimated existing dates.
3. Invoke `task_sync_website` if the packaged registry also needs publication.
4. Let the next scheduled refresh populate Valkey, or invoke
   `task_refresh_package_tracker` immediately, then inspect the page and task logs.

The schedule needs no new Lambda, HTTP credentials, database, or enablement
parameter. Tracker widgets become visible automatically when cached results are
available; ordinary package browsing works without them.
