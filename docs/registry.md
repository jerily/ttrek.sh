# Package registry and search

[Documentation](readme.md) · [Project overview](../README.md)

The public package catalog lives in the `registry` Git submodule. See
[setup](install.md#get-the-source) to clone the website with its registry.
Commands below run from the website checkout.

Recipes carry a top-level `description`, optional `tags`, project `url`, and SPDX `license` string.
The package overview shows the latest version's description, HTTP(S) project link, and license when present.

The explicit `task_sync_website` invocation (`sync-local` for the local Lambda) imports the configured/bundled registry
into the telemetry `packages` table, storing `description`, `url`, `license`, and JSON `tags` per version. Package names are stored in `package_names`.
Schema upgrades belong to `task_initdb_website`, independently of synchronization. Repeated imports
update changed metadata without replacing package IDs or installation history;
unchanged rows are not rewritten. Missing descriptions/URLs/licenses preserve existing values and
default to empty strings for new packages. Missing tags become an empty array.
The `listed` flag separates current recipes from telemetry-only names and withdrawn
versions without deleting installation history. Old telemetry backups remain restorable;
run registry sync after restoring an older backup to repopulate the published catalog.

After `::telemetry::connect $settings` and an explicit `::telemetry::initdb`
when provisioning is needed, imports can include multiple local registries:

```tcl
::telemetry::sync_registry_metadata /path/to/ttrek-registry /path/to/private-ttrek-registry
```

Duplicate name/version pairs are rejected before writing. Private recipes are
imported only when their directory is explicitly supplied.

## Update package recipes

Make package changes in `jerily/ttrek-registry` and publish them there first.
Then update the website's pinned registry commit and commit the change in
`ttrek.sh`:

```bash
git -C registry fetch origin
git -C registry checkout --detach origin/main
git add registry
git commit -m "Update registry submodule"
```

The website reads package specifications and patches from `[registry] directory`
in the application configuration:

```ini
[registry]
directory = registry
```

The default is the `registry` submodule. Relative paths resolve against the
application root, and absolute paths can point to a separate registry checkout.
Set this in `etc/config.local.ini` for LOCAL mode or the production configuration
for PROD mode. Both modes connect without provisioning or importing data. Run
`task_initdb_website` for schema upgrades and `task_sync_website` to import metadata
and publish search indexes. Locally, use `initdb-local` and `sync-local`. Overviews, package listings,
and search read the database. Recipe/dependency API routes and version build details
still read this directory. The build uses the pinned submodule for its patch files.

Recipe scripts can reference files beside their spec, for example
`"scripts": {"demo": {"file": "demo.sh"}}`. The API reads these UTF-8 files
and returns their contents as script strings, preserving compatibility with
installed-script caching. Only regular files directly in the recipe directory
are accepted; paths and symbolic links are rejected. Inline scripts also work.

Registry recipes use `if: "+static"` for optional static build settings.
Enable them with `ttrek gen-script -static` or `useFlags: ["+static"]` in the project.
Without the flag, recipes keep their normal defaults.
Static Tcl extensions are intended for embedding, not `package require` loading.

## Recipe search

`GET /registry/search?q=web` returns JSON objects with `name`, `description`, `tags`, and
`match`. Ranking: exact name, prefix, substring, literal description, literal tag,
name typo, description typo, tag typo. Ties prefer fewer edits, greater query-trigram coverage, less
unmatched name text, then name. `distance` is omitted for prefix/substring name
matches; `coverage` is shared/total unique query trigrams for description hits.
Tag hits use `field: "tags"` with the existing `description` or `description-fuzzy`
match value so older CLI clients can still consume the results.

`GET /registry/autocomplete?q=web` returns up to eight `{name, description}`
objects with the same ranking and validation. Both endpoints read the database catalog. `GET /search?q=web` renders the full results page; `/packages` browses
all packages. The home and registry pages share an accessible search form with
keyboard navigation and a 200 ms `throttle-debounce` throttle. Pending lookups
are cancelled and stale responses ignored. Normal form submission works without
JavaScript, including when suggestions are unavailable.

Matching ignores ASCII case. Queries accept 1–255 ASCII letters, digits, spaces,
`.`, `_`, `+` and `-`, excluding empty queries, `.` and `..`. Encode literal `+`
as `%2B`. Invalid queries return 400; no matches returns `[]`. Queries of at most
three characters allow one edit, longer queries two. Description and tag suggestions
require a shared trigram and a verified substring distance; below three
characters descriptions and tags match literally. Tags are searched individually.

Search is a two-step operation. Workers rank matches using cached native indexes,
then fetch display metadata from the package tables only for those matches.
Autocomplete limits the ranked names to eight before fetching metadata. Package
listings and overviews read the database directly and do not load search indexes.

`task_sync_website` builds both indexes after importing the catalog, and commits
the catalog and complete snapshot together. The singleton `registry_search_snapshot`
row has separate binary `names` and `descriptions` columns (SQLite BLOB / PostgreSQL
bytea), a JSON `mapping` of names and document-to-package/version/field references,
format version, input fingerprint, and payload revision. It does not duplicate the
full catalog, descriptions, tags, or URLs in JSON. The native trigram index already
contains the searchable text. Unchanged search inputs, including URL-only edits,
skip rebuilding and publication. Publishers serialize on the singleton row.

Workers start with unloaded caches. The first search fetches the complete snapshot;
warm searches check only its revision and fetch blobs only when it changes. Native
loaders restore the structures without index construction. Validation covers the
format, checksum, mapping, document count and indexed names before both indexes
and their mapping replace the active generation. The fetched payload supplies its
own revision, even when publication races with the initial check.

Metadata retrieval validates the worker's revision within a consistent database
transaction (repeatable-read on PostgreSQL). Readers can keep using the committed
generation while a sync prepares its replacement. If publication occurred after ranking, search refreshes and retries
(up to three attempts). Failed refreshes log a diagnostic and retain the last good
indexes. They may serve requests only while the database still confirms that
revision; otherwise search returns 503 with `Retry-After: 30` and `Cache-Control:
no-store`. There is no request-time rebuild or full-catalog fallback. Keeping the
indexes cannot make unavailable database metadata available.

Use `task_publish_search` to publish directly edited database search fields without
reimporting recipes. This explicit maintenance task forces reconstruction, so it
also repairs a damaged snapshot with an unchanged input fingerprint.
Names, descriptions, tags and listing changes need publication;
display-only fields such as URLs remain immediately visible without rebuilding.
For atomic database maintenance, acquire `::telemetry::lock_search_snapshot` before
editing inside `::telemetry::transaction`, then call
`::telemetry::publish_search_snapshot` before committing. Requests never scan
recipe files or load `etc/search-index.json`. The direct server uses the telemetry
thread for database calls; Lambda uses its existing connection.

All version descriptions and tags are indexed, with one result per package.
Description hits display the matched text; name and tag hits use the first nonempty
description in alphabetical order. Overviews use the latest published version's
metadata. Missing descriptions and tags are allowed. Tags are optional arrays of
nonempty, single-line strings of at most 255 UTF-8 bytes. Overviews and result cards
omit the tag list when no tags are present.

`ttrek run -script build-search` remains an optional offline snapshot helper for
registry inspection and regression tests. Its output is not used by the website;
normal builds and Lambda packaging no longer require it.
The helper now writes format 3; regenerate older offline artifacts before loading
them with the new codec.

The recipe API returns the selected version's `scripts` object together with
its dependencies, build instructions, USE flags and patches. Both registry
endpoints omit recipe devDependencies, following npm semantics: development
dependencies are installed only for the root project. Missing scripts
are represented as an empty object. Script bodies remain JSON strings; the
website does not execute them. The CLI saves them with the installed package
for offline `ttrek run -package PACKAGE -script NAME` and
`ttrek scripts -package PACKAGE ls|describe` commands.
