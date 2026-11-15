# ttrek scripts

List, inspect, add, or remove named project scripts in `ttrek.json`.

## Usage

```text
ttrek scripts [-u|-g] [-package PACKAGE] ls
ttrek scripts [-u|-g] [-package PACKAGE] describe NAME
ttrek scripts [-u|-g] add NAME BODY
ttrek scripts [-u|-g] del NAME
```

| Action | Description |
| --- | --- |
| `ls` | List script names. |
| `describe NAME` | Inspect a script. For a file reference, read the file relative to the project root. |
| `add NAME BODY` | Store an inline shell script body. |
| `del NAME` | Remove a project script. |

Use `-u` or `-g` to select the user or global environment. These commands do not
fetch recipes or execute scripts.

## Project scripts

Project scripts may be shell strings or file references:

```json
{"file":"bin/task.sh","args":["preset"]}
```

File `args` must be an array of strings. They are passed before arguments
supplied after `--` when running the script. Editing other scripts preserves
existing file references.

## Installed package scripts

`-package` selects scripts cached with an installed package's exact recipe
version. Package scripts are read-only and support only `ls` and `describe`.

Run a package script with:

```text
ttrek run -package PACKAGE -script NAME
```

Reinstall older packages with `ttrek install -force PACKAGE` to cache their
recipe scripts. Use the same `-u` or `-g` mode for installation and execution.
