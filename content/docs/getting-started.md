# Getting started

ttrek manages Tcl packages and their native dependencies in a project environment.

## Install the command-line tool

```sh
curl --proto '=https' --tlsv1.2 -sSf https://ttrek.sh/init | sh
```

Open a new terminal after installation so your shell picks up the executable.

## Create a project

```sh
mkdir my-app
cd my-app
ttrek init -y
ttrek sync
ttrek install -y tcl tjson
```

`ttrek.json` records direct dependencies. `ttrek-lock.json` records the resolved
versions and registry selection. Packages install under `ttrek-venv/local`.
Keep application data outside `ttrek-venv`.

## Run Tcl in the project environment

```sh
ttrek run tclsh9.1
```

At the Tcl prompt:

```tcl
package require tjson
puts [package present tjson]
```

Use `ttrek install -y` to install a project's declared dependencies. See
[Managing packages](/docs/managing-packages) and
[Registries](/docs/registries) for version selection and private packages.
