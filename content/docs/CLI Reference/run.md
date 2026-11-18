# ttrek run

Run a named shell script from the project's `ttrek.json`, or a command in its
installed environment.

For an interactive Bash or Zsh session, use [ttrek activate](/docs/cli-reference/activate).

## Usage

```text
ttrek run [-u|-g] [-package PACKAGE] -script NAME [-- ARGS...]
ttrek run [-u|-g] COMMAND [ARGS...]
```

`-package` selects scripts saved with an installed package's recipe. It requires
`-script` and does not contact a registry. Use `-u` or `-g` to select the user or
global environment.

## File-based project scripts

Project scripts can reference an executable file:

```json
{"file":"bin/task.sh","args":["preset"]}
```

The file must be a regular executable, relative to the project root, without
`..` components or a symbolic link. It runs at its original path so its shebang
and script-relative paths keep working. `args` is an optional array of strings,
passed before arguments supplied after `--`, without shell expansion.

## Passing arguments

Pass script arguments after `--`. They are forwarded literally as `$1`, `$2`,
and so on. Shell scripts should use `"$@"` to forward them to their program.

```sh
ttrek run -package my-app -script start -- --port 3015 --data-dir "my data"
```

Options after `--` are never interpreted as ttrek options. The separator also
works with direct commands:

```text
ttrek run -- COMMAND [ARGS...]
```

## Package scripts

Use `ttrek scripts -package PACKAGE ls` to list available package scripts.
Older installations without cached scripts need `ttrek install -force PACKAGE`
with a recipe containing scripts. Use the same `-u` or `-g` mode when reinstalling.

## Execution environment

Scripts run in the installation directory with its `bin` directory on `PATH`
and its libraries on `LD_LIBRARY_PATH`. `PROJECT_HOME` is the project root and
`PROJECT_INSTALL_DIR` is the absolute installation prefix. `SHELL` must be set.
Store runtime data outside `ttrek-venv` so package operations do not manage it.
