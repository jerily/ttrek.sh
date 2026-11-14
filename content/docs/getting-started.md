# Getting started

ttrek manages Tcl packages and their native dependencies in a project environment.

## Install the command-line tool

```sh
curl --proto '=https' --tlsv1.2 -sSf https://ttrek.sh/init | sh
```

Open a new terminal after installation so your shell picks up the executable.

## Install build tools

Before installing packages on Ubuntu/Debian:

```sh
sudo apt update
sudo apt install build-essential cmake bash curl git patch pkg-config perl tar gzip ca-certificates
```

`build-essential` supplies GCC, G++ and Make. For a newer CMake, use
`sudo snap install cmake --classic` and include `/snap/bin` on `PATH`.
`ttrek install` and `ttrek update` report missing external tools before changing
the project environment. Individual package recipes may need additional tools.

## Create a project

```sh
mkdir my-app
cd my-app
ttrek init -y
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

For a complete project to try, follow [Build websites with ttrek](/docs/build-websites-with-ttrek)
to run a personal site and a community site with accounts.

To learn how an app saves data between runs, try
[Database Persistence Layer with tpersist](/docs/database-persistence-layer).
Build a task list with a JSON schema, SQLite locally, and PostgreSQL in production.
