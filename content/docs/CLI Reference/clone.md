# ttrek clone

Download and unpack a package's source archive into a local directory.

## Usage

```text
ttrek clone [-outdir DIRECTORY] [-registry SOURCE]... [-add-pubreg] PACKAGE[@VERSION]
```

Exactly one package is required. `VERSION` is optional and accepts the same
semantic version constraints as [install](/docs/cli-reference/install). The
newest matching version is used.

## Destination

The destination defaults to `./PACKAGE`. Use `-outdir` to choose a different
directory, including `.` for the current directory. The destination must be
new or empty; existing files and symlinks are never overwritten. Parent
directories are created if needed. A failed download or extraction leaves
the destination untouched and removes temporary files.

## Registry selection

ttrek uses explicit registry options, the nearest project's saved registry,
the synced public registry, then `https://ttrek.sh/registry`. The command also
works outside projects. Use `-registry SOURCE` to select sources and
`-add-pubreg` to append the public default.

## What gets cloned

Clone retrieves the primary download/unpack pair from the current platform's
recipe, strips the archive's enclosing directory, and preserves file modes
and timestamps. Packages without a source archive, including metapackages and
Git-only recipes, report an error. Conditional source archives require USE
flag selection and are not supported by `clone`.

Dependencies, patches, additional archives, hooks, and build steps are not run.
ttrek does not create project state, a lockfile, an environment, or Git history.
Files already present in the source archive are kept.

## Examples

```sh
ttrek clone tsession
ttrek clone tsession@1.1.0 -outdir ./my-session
ttrek clone -outdir . 'tcl@>=8.6.0,<9.0.0'
```
