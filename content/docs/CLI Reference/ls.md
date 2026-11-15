# ttrek ls

List packages recorded in the selected environment's `ttrek-lock.json`, one
`PACKAGE@VERSION` per line. The list includes direct and transitive dependencies.
It reflects resolved versions and does not verify installed files.

## Usage

```text
ttrek ls [-u|-g] [PATTERN ...]
```

## Filtering packages

Without patterns, list all locked packages. `PATTERN` matches package names,
not versions, using case-sensitive Tcl glob syntax:

| Pattern | Meaning |
| --- | --- |
| `*` | Any sequence of characters. |
| `?` | One character. |
| `[abc]` or `[a-z]` | A character from a set or range. |

Quote patterns to prevent your shell from expanding them. Multiple patterns
are processed in order; a package matching more than one may appear again.
A pattern with no matches prints nothing.

## Environment

By default, use the current project environment (`ttrek-venv`). `-u` selects
the user environment (`~/.local`); `-g` selects the global environment
(`/usr/local/ttrek`). These options cannot be combined.

## Examples

```sh
ttrek ls
ttrek ls 'tcl*'
ttrek ls tjson 'web-*'
ttrek ls -u
```
