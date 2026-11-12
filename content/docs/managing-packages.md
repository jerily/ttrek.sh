# Managing packages

## Find and install packages

```sh
ttrek search tcl
ttrek search 'web server'
ttrek install -y tjson
ttrek install -D -y twebserver
```

`-D` saves explicitly named packages in `devDependencies`. Normal installs save
them in `dependencies`. A package belongs in one section only; installing an
existing package with `-D` moves it without requiring an unnecessary rebuild.

Version constraints can be explicit:

```sh
ttrek install -y 'tjson@^1.0.26'
ttrek install -y 'tcl@>=9.1.0,<10.0.0'
```

Caret constraints accept compatible versions in the same major version.

## Update dependencies

```sh
ttrek update -y tjson
ttrek update -y
```

Install normally favors locked versions. Update normally selects the latest
compatible versions. `-strategy locked` requires the locked candidates to remain
available. Changed packages and their dependent packages are rebuilt; unchanged
dependencies are reused.

## Run commands and scripts

```sh
ttrek run tclsh9.1 app.tcl
ttrek scripts -package web-wiki ls
ttrek run -package my-app -script start -- --port 8081
```

Named scripts run inside the installed environment. Their `PROJECT_HOME` points
to the project and `PROJECT_INSTALL_DIR` to its installation prefix. Arguments
after `--` are passed to the script.

## Generate a standalone build

```sh
ttrek gen-script > build.sh
bash build.sh
```

The generated script includes dependency recipes in build order and installs
under `build/install` beside the script. It does not need a ttrek executable at
build time. Generation itself does not install or change project dependencies.
