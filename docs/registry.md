# Package registry and search

[Documentation](readme.md) · [Project overview](../README.md)

The public package catalog lives in the `registry` Git submodule. See
[setup](install.md#get-the-source) to clone the website with its registry.
Commands below run from the website checkout.

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
for PROD mode. Build search with the same registry directory, then restart the
server. All package pages and registry API routes use this directory. The build still uses the pinned submodule for its patch files.

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

`GET /registry/search?q=web` returns JSON objects with `name`, `description`, and
`match`. Ranking: exact name, prefix, substring, literal description, name typo,
description typo. Ties prefer fewer edits, greater query-trigram coverage, less
unmatched name text, then name. `distance` is omitted for prefix/substring name
matches; `coverage` is shared/total unique query trigrams for description hits.

`GET /registry/autocomplete?q=web` returns up to eight `{name, description}`
objects with the same ranking and validation. Both endpoints use the loaded build
snapshot. `GET /search?q=web` renders the full results page; `/packages` browses
all packages. The home and registry pages share an accessible search form with
keyboard navigation and a 200 ms `throttle-debounce` throttle. Pending lookups
are cancelled and stale responses ignored. Normal form submission works without
JavaScript, including when suggestions are unavailable.

Matching ignores ASCII case. Queries accept 1–255 ASCII letters, digits, spaces,
`.`, `_`, `+` and `-`, excluding empty queries, `.` and `..`. Encode literal `+`
as `%2B`. Invalid queries return 400; no matches returns `[]`. Queries of at most
three characters allow one edit, longer queries two. Description suggestions
require a shared trigram and a verified substring distance; below three
characters descriptions match literally.

`ttrek.sh` builds and serializes both indexes **at build time**, using ttrie and
ttrigrams 0.2.0. Workers call `::recipe_search::load` to restore the trie nodes
and sorted trigram postings directly; they never scan recipes or construct an
index. All version descriptions are indexed, with one result per package.
Description hits display the matched text; name hits use the first nonempty
description in alphabetical order. Missing descriptions are allowed.

For direct serving, build after installing dependencies and whenever recipes change:

```sh
ttrek run -script build-search
# Custom [registry] directory: use the same directory as the server configuration.
ttrek run -script build-search -- /path/to/registry
```

`bin/build-search.tcl ?registry_directory? ?output_file?` defaults to the pinned
`registry` and `etc/search-index.json` relative to the application root.
`build.sh` and CodeBuild run it for the pinned registry.
Lambda packaging builds it from the staged registry in `devops/prepare-lambda.tcl`.
Restart workers after rebuilding, or repackage and restart the local mock stack.

The artifact is one versioned JSON document with display metadata and Base64
binary snapshots. Binary indexes preserve the native structures without pointer,
alignment or host-endian dependencies. JSON keeps metadata inspectable; putting
both snapshots in one atomically replaced file prevents partial publication.
The artifact is generated, not committed. Missing/invalid snapshots fail startup;
failed builds and loads preserve the previous artifact or active indexes.
Only trusted build output should be loaded. `build.sh` installs both extensions
using Tcl stubs.

The recipe API returns the selected version's `scripts` object together with
its dependencies, build instructions, USE flags and patches. Both registry
endpoints omit recipe devDependencies, following npm semantics: development
dependencies are installed only for the root project. Missing scripts
are represented as an empty object. Script bodies remain JSON strings; the
website does not execute them. The CLI saves them with the installed package
for offline `ttrek run -package PACKAGE -script NAME` and
`ttrek scripts -package PACKAGE ls|describe` commands.
