# Package registry and search

[Documentation](readme.md) · [Project overview](../README.md)

The public package catalog lives in the `registry` Git submodule. See
[setup](install.md#get-the-source) to clone the website with its registry.
Commands below run from the website checkout.

Recipes carry a top-level `description`, optional `tags`, and project `url`. The package overview
shows the latest version's description and HTTP(S) project link.

LOCAL startup imports the configured/bundled registry. In PROD, the explicit
`task_sync_website` invocation imports it
into the telemetry `packages` table, storing `description`, `url`, and JSON `tags` per version. Package names are stored in `package_names`.
Schema upgrades belong to `task_initdb_website`, independently of synchronization. Repeated imports
update changed metadata without replacing package IDs or installation history;
unchanged rows are not rewritten. Missing descriptions/URLs preserve existing values and
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
for PROD mode. LOCAL startup imports it; in PROD, run `task_initdb_website` for
schema upgrades and `task_sync_website` to import metadata. Overviews, package listings,
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

Each catalog request reads published name/version metadata from the database.
Workers cache ttrie and ttrigrams indexes, rebuilding them only when those rows
change. Syncs and database edits are visible to warm workers on the next request;
requests never scan recipe files or read `etc/search-index.json`. In the direct
server, the existing telemetry thread owns the database connection; Lambda uses
its existing connection. Startup does not require catalog tables so explicit
provisioning tasks can initialize a new deployment.

All version descriptions and tags are indexed, with one result per package.
Description hits display the matched text; name and tag hits use the first nonempty
description in alphabetical order. Overviews use the latest published version's
metadata. Missing descriptions and tags are allowed. Tags are optional arrays of
nonempty, single-line strings of at most 255 UTF-8 bytes. Overviews and result cards
omit the tag list when no tags are present.

`ttrek run -script build-search` remains an optional offline snapshot helper for
registry inspection and regression tests. Its output is not used by the website;
normal builds and Lambda packaging no longer require it.

The recipe API returns the selected version's `scripts` object together with
its dependencies, build instructions, USE flags and patches. Both registry
endpoints omit recipe devDependencies, following npm semantics: development
dependencies are installed only for the root project. Missing scripts
are represented as an empty object. Script bodies remain JSON strings; the
website does not execute them. The CLI saves them with the installed package
for offline `ttrek run -package PACKAGE -script NAME` and
`ttrek scripts -package PACKAGE ls|describe` commands.
