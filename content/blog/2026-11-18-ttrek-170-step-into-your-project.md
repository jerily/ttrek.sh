# ttrek 1.7.0: step into your project's environment

![A miniature developer workspace inside a terminal window, with a glowing doorway, package cubes, and a (ttrek) prompt.](images/ttrek-170-activate.jpg)

**ttrek 1.7.0 introduces `ttrek activate`: an interactive shell with your
project's installed tools ready to use.** Activate once, run commands directly,
and use `deactivate` when you are done.

If you already use `ttrek run` to launch a command with your project's
dependencies, this will feel familiar. Activation gives you the same
environment for a whole interactive Bash session. It is handy when you want
to explore a library, try a few commands, or work at the Tcl prompt.

## From a fresh directory to the Tcl prompt

Create a project, initialize it, and install Tcl and tjson. Then activate the
environment and try parsing a little JSON:

```text
$ mkdir my-project
$ cd my-project
$ ttrek init -y
$ ttrek install -y tcl tjson
$ ttrek activate
(ttrek) $ which tclsh9.1
/path/to/my-project/ttrek-venv/local/bin/tclsh9.1
(ttrek) $ tclsh9.1
% package require tjson
1.0.28
% set json [::tjson::parse {{"a":1,"b":2}}]
_TJSON_0x5bc3772fa330
% ::tjson::to_simple $json
a 1 b 2
% exit
(ttrek) $ deactivate
$
```

Setup and installation output is omitted here. Your absolute path and JSON
handle will differ, and package versions may change as the registry grows.

The `(ttrek)` prefix tells you that the environment is active. The `which`
output shows that `tclsh9.1` comes from this project's `ttrek-venv/local/bin`.
Inside Tcl, `package require tjson` loads the installed library, and
`::tjson::to_simple` converts the parsed JSON object into a Tcl dictionary.

## What activation does

`ttrek activate` opens an interactive Bash shell in your current directory.
It finds the project through `ttrek.json` in that directory or a parent, so
you can activate from a subdirectory too.

The shell loads your `~/.bashrc`, then applies the project's environment:

- The installation's `bin` directory goes first on `PATH`.
- `LD_LIBRARY_PATH` points to the installation's `lib` directory.
- `PROJECT_HOME` and `PROJECT_INSTALL_DIR` identify the project root and
  installation prefix.

Your Bash aliases and settings are available, and the `(ttrek)` prefix makes
the active environment easy to recognize. Bash must be available on `PATH`.

## Deactivate, or leave the shell

In the example, the first `exit` leaves the Tcl interpreter. You are back at
the `(ttrek)` shell prompt, where `deactivate` restores the environment and
prompt saved after Bash startup. Your installed packages stay in place.

`deactivate` keeps that Bash session open. To return to the shell you started
from, run `exit` or press **Ctrl-D**. You can also leave the activated Bash
session directly this way, without deactivating first. The parent shell's
environment is unchanged.

## A few useful options

For user or global installations, use `ttrek activate -u` or
`ttrek activate -g`. If you prefer to keep your existing prompt, launch with:

```sh
TTREK_VENV_DISABLE_PROMPT=1 ttrek activate
```

For a single command, `ttrek run tclsh9.1` is still available. Choose activation
when you want to stay and work with the installed tools. Run
`ttrek help activate` for the full command reference.

## Get ttrek 1.7.0

Update ttrek and check your installed version:

```sh
ttrek self-update
ttrek version
```

New here? [Get started with ttrek](/docs/getting-started), browse the
[package registry](/packages), or try [building a website](/docs/build-websites-with-ttrek).
