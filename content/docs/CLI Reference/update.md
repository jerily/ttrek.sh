# ttrek update

Update project dependencies. The default resolution strategy is `latest`.

## Usage

```text
ttrek update [-registry SOURCE]... [-add-pubreg] [-strategy latest|favored|locked] [-y] [-force] [-keep] [-u|-g] [PACKAGE[@VERSION_RANGE] ...]
```

## Options

| Option | Description |
| --- | --- |
| `-registry SOURCE` | Append a local directory or HTTP(S) API URL. Repeat to set lookup order. |
| `-add-pubreg` | Append the public default after explicit or saved sources: the synced local copy, otherwise the API. Does not change saved configuration. |
| `-strategy STRATEGY` | Choose `latest` (default), `favored`, or `locked`. |
| `-y` | Accept the update confirmation. |
| `-force` | Rebuild targeted packages and their transitive reverse dependencies even when unchanged. |
| `-keep` | Preserve sources, downloads, patches, and build directories. |
| `-u` | Update the user environment. |
| `-g` | Update the global environment. |

The first registry containing a package supplies its versions and recipe.
Only an absent package advances to the next registry; other errors stop lookup.
Explicit sources replace the saved list and defaults for this invocation.

## Version selection and rebuilds

Both `dependencies` and `devDependencies` participate, retaining their sections.
Without package arguments, `update` considers the entire dependency graph, using
root constraints from both sections. All locked packages remain in the resolution
graph; `latest` chooses the newest versions satisfying the root and transitive
constraints.

A named update keeps its saved range unless `NAME@RANGE` explicitly replaces it.
Unrequested locked versions are favored when compatible with the requested change.

New packages, changed versions or USE flags, forced targets, and their transitive
reverse dependencies form the execution plan. Unchanged forward dependencies and
unrelated packages are not rebuilt. An already-current, fully installed graph
does not rebuild packages.

The resolved versions refresh `ttrek-lock.json`, including packages already
installed. Installed-state checks use `ttrek-venv/ttrek-manifest.json` and its
recorded files.

## Build files

Successful packages have their private source trees, patches, and build
directories removed. Shared sources and downloads are removed after the entire
operation succeeds. Build logs and generated install scripts are retained.
Failed packages keep their sources and build files; failed operations keep
shared caches. No-op and cancelled operations do not clean caches.

Use `-keep` to preserve these files for the invocation:

```sh
ttrek update -keep -y
```
