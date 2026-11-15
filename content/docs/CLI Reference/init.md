# ttrek init

Create `ttrek.json`, `ttrek-lock.json`, and the project environment.

## Usage

```text
ttrek init [-y] [-registry SOURCE]... [-add-pubreg]
```

## Options

| Option | Description |
| --- | --- |
| `-y` | Accept the default project name and version. |
| `-registry SOURCE` | Save a registry directory or HTTP(S) API URL in `ttrek-lock.json`. Repeat to set lookup order. |
| `-add-pubreg` | Append the public default after the selected sources and save it as a portable public entry. |

## Saved registries

A single local directory is stored under `registry`; other source lists use
`registries`. Later `install`, `update`, `pretend`, and `gen-script` commands
reuse these sources unless overridden. Relative saved paths resolve from the
project directory.

`-add-pubreg` saves `{"public":true}` as the last `registries` entry. It uses
the synced `~/.local/ttrek-registry` when available, otherwise
`https://ttrek.sh/registry`, without saving a machine-specific path.

The first registry containing a package supplies its versions and recipe.
Only an absent package advances to the next registry; other errors stop lookup.
Explicit sources replace the saved list and defaults for the invocation.
