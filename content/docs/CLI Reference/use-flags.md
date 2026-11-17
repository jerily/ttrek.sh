# ttrek use-flags

Configure USE flags for one installation in its `ttrek-manifest.json`.

## Usage

```text
ttrek use-flags SUBCOMMAND [-u|-g] [--] [+flag|-flag ...]
```

Without `-u` or `-g`, the command selects the current project's `ttrek-venv`
installation. Mode options follow the subcommand and cannot be combined.

## Subcommands

| Subcommand | Description |
| --- | --- |
| `ls` | Print the configured flags, one per line. |
| `set [flags ...]` | Replace the flags. With no flags, clear the list. |
| `add flags ...` | Add flags or change their existing polarity. |
| `del flags ...` | Remove settings by name, regardless of polarity. |

## Options

| Option | Description |
| --- | --- |
| `-u` | Select the user installation. |
| `-g` | Select the global installation. |
| `--` | End mode options, for example when configuring a flag named `u` or `g`. |

## Flag syntax

Each flag starts with `+` (enabled) or `-` (explicitly disabled), followed by
letters, digits, underscores, dots, or hyphens. Names are case-sensitive.

`set` rejects conflicting polarities for the same name. `add` applies arguments
in order, so the last setting for a name wins. `del +debug` and `del -debug`
both remove the setting for `debug`.

An absent flag is disabled. A condition of `"if": "-local"` matches when
`local` is absent or explicitly disabled; `"if": "+local"` requires `+local`.
Whitespace-separated conditions are ANDed, so `"+local -debug"` requires
`local` to be enabled and `debug` to be disabled.

Project `dependencies` and `devDependencies` accept conditional entries such
as `{"version": "^1.0.0", "if": "+local"}` as well as plain version strings.
Recipe dependencies, build steps, and options use the same condition rules.

Declare supported names with `"iuse": ["local"]` in project or recipe metadata.
Names in `iuse` are unsigned and never enable flags. Registries also infer
names from recipe conditions.

## Settings and rebuilds

Settings are read and written only in the selected installation's
`ttrek-manifest.json`. There is no migration or fallback from `ttrek.json`.
A missing `useFlags` field means all flags are disabled.

Changing settings does not build packages or change their last-built flags.
Run [`ttrek pretend`](/docs/cli-reference/pretend) to preview the current
project's changes, then [`ttrek install`](/docs/cli-reference/install) to
rebuild affected packages. If you selected `-u` or `-g`, use the same mode
with `install`.

Each package's manifest `iuse` is an array of unsigned names. Its `use` records
the effective signed value of every name at its last successful build,
including negative defaults. Last-built flags are never stored in `ttrek.json`.

Disabled dependencies leave the selected lock graph. Previously installed files
remain tracked in the manifest until explicitly uninstalled. Use a fresh
installation for production artifacts when switching from a local build.

## Examples

Inspect, replace, add, remove, or clear settings:

```sh
ttrek use-flags ls
ttrek use-flags set +static -debug
ttrek use-flags add -debug
ttrek use-flags del +debug
ttrek use-flags set
```

Select the user installation, or use `--` to configure a flag named `u`:

```sh
ttrek use-flags add -u +static
ttrek use-flags add -- -u
```

Enable `local`, apply it, then remove the setting:

```sh
ttrek use-flags add +local
ttrek install
ttrek use-flags del +local
```
