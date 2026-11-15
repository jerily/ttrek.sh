# ttrek pretend

Preview the installation plan using the same solver and planner as
`install` and `update`.

## Usage

```text
ttrek pretend [-registry SOURCE]... [-add-pubreg] [-strategy latest|favored|locked] [-force] [PACKAGE[@VERSION_RANGE] ...]
```

The command reads `ttrek.json` and, when present, `ttrek-lock.json` and
`ttrek-venv/ttrek-manifest.json`. It checks installed files and prints the
install plan. It does not write project files, create a virtual environment,
run hooks, or install packages.

## Options

| Option | Description |
| --- | --- |
| `-registry SOURCE` | Append a local directory or HTTP(S) API URL. Repeat to set lookup order. |
| `-add-pubreg` | Append the public default after explicit or saved sources: the synced local copy, otherwise the API. Does not change saved configuration. |
| `-strategy STRATEGY` | Use `favored` (default, as for `install`), `latest` to preview an update, or `locked`. |
| `-force` | Preview a forced reinstall using the install planner. |

The first registry containing a package supplies its versions and recipe.
Only an absent package advances to the next registry; other errors stop lookup.
Explicit sources replace the saved list and defaults for this invocation.

## Examples

```sh
ttrek pretend tjson twebserver
ttrek pretend -strategy latest
```
