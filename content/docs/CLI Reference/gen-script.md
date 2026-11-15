# ttrek gen-script

Write a standalone build script to standard output. Resolve project dependencies
and include their recipes and patches in build order.

## Usage

```text
ttrek gen-script [-registry SOURCE]... [-add-pubreg] [-shell bash|sh] [-static] [-strategy latest|favored|locked] [PACKAGE[@VERSION_RANGE] ...]
```

With no package arguments, the script also includes the project's build recipe.
Hooks run when the generated script is executed, not during generation.
Generation does not install packages, change project files, or send telemetry.

## Options

| Option | Description |
| --- | --- |
| `-registry SOURCE` | Append a local directory or HTTP(S) API URL. Repeat to set lookup order. |
| `-add-pubreg` | Append the public default after explicit or saved sources: the synced local copy, otherwise the API. Does not change saved configuration. |
| `-shell bash` or `-shell sh` | Select the script's shell. The default is `bash`. |
| `-static` | Enable the `+static` USE flag for conditional recipe options. |
| `-strategy STRATEGY` | Select the `latest`, `favored`, or `locked` resolution strategy. |

The script installs into `build/install` beside the script and needs no ttrek
binary. Static Tcl extensions require registration by an embedding application.

The first registry containing a package supplies its versions and recipe.
Only an absent package advances to the next registry; other errors stop lookup.
Explicit sources replace the saved list and defaults for this invocation.

## Examples

```sh
ttrek gen-script > build.sh
ttrek gen-script -registry ../ttrek.sh/registry > build.sh
ttrek gen-script -shell sh -static jinja2-tcl > build.sh
bash build.sh
```
