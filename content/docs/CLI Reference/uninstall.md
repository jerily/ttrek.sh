# ttrek uninstall

Remove one or more packages from the selected environment, along with installed
packages that depend on them directly or indirectly.

## Usage

```text
ttrek uninstall [-y] [-autoremove] [-u|-g] [-strategy latest|favored|locked] PACKAGE ...
```

Supply exact package names, without version constraints or glob patterns.
At least one package is required. The removal plan is printed before
confirmation; enter `y` to proceed, or use `-y` to accept it automatically.

## Options

| Option | Description |
| --- | --- |
| `-y` | Accept the removal plan without prompting. |
| `-autoremove` | Also remove dependencies of removed packages when they have no remaining dependants. |
| `-u` | Select the user environment (`~/.local`). |
| `-g` | Select the global environment (`/usr/local/ttrek`). |
| `-strategy STRATEGY` | Accepted, but does not change the removal plan. |

Without `-u` or `-g`, use the current project environment (`ttrek-venv`).
The `-u` and `-g` options cannot be combined.

## Removal plan

The plan uses the installed manifest's reverse dependencies and the lockfile's
dependency relationships. Without `-autoremove`, dependencies of removed packages
are kept unless they are explicitly selected or also depend on a removed package.

> Review the full plan, especially when removing a shared dependency: its
> installed dependants are removed too.

Removal deletes the package files recorded in the installed manifest and removes
the package entries from `ttrek.json`, `ttrek-lock.json`, and the installed
manifest. Direct dependencies are removed from `dependencies` or
`devDependencies` as applicable.

## Examples

```sh
ttrek uninstall twebserver
ttrek uninstall -y tjson twebserver
ttrek uninstall -autoremove web-blog
ttrek uninstall -u tjson
```
