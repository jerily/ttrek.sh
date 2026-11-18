# ttrek activate

Open an interactive Bash or Zsh shell with the installed environment and a
`(ttrek)` prompt. Activation keeps your current directory and makes installed
tools available for the whole shell session.

## Usage

```text
ttrek activate [-u|-g]
```

Local mode finds `ttrek.json` in the current directory or a parent, so you can
activate from a project subdirectory. Use `-u` for the user installation or
`-g` for the global installation.

```sh
ttrek activate
ttrek activate -u
ttrek activate -g
```

## Shell selection and startup

On Linux and macOS, ttrek detects Bash or Zsh from the parent process. If it
cannot identify a supported shell, it uses a supported shell named by `SHELL`,
or defaults to Bash. `SHELL` need not be set.

The detected shell must be available on `PATH`. When falling back to `SHELL`,
ttrek uses its path directly.

Bash reads `~/.bashrc`. Zsh reads `.zshenv` and `.zshrc`, respecting `ZDOTDIR`.
Activation applies the environment and prompt prefix after the startup files.

## Environment

Activation sets the same environment as [ttrek run](/docs/cli-reference/run):

| Variable | Value |
| --- | --- |
| `PATH` | Installation `bin` directory followed by the inherited `PATH`. |
| `LD_LIBRARY_PATH` | Installation `lib` directory. |
| `PROJECT_HOME` | Project root. |
| `PROJECT_INSTALL_DIR` | Absolute installation prefix. |

It also exports `TTREK_VENV`, the `ttrek-venv` directory, and
`TTREK_VENV_PROMPT=ttrek`. Python's `VIRTUAL_ENV` and `PYTHONHOME` are left alone.

## Prompt

By default, activation prefixes the shell's prompt with `(ttrek)`. To leave
the prompt unchanged:

```sh
TTREK_VENV_DISABLE_PROMPT=1 ttrek activate
```

## Deactivate or exit

Run `deactivate` to restore the environment and prompt saved after shell
startup. This keeps the shell session open.

Run `exit` or press **Ctrl-D** to return to the parent shell, with or without
deactivating first. The parent shell's environment is unchanged.

For a single command or named script, use [ttrek run](/docs/cli-reference/run).
To read this command's help in your terminal, run `ttrek help activate`.
