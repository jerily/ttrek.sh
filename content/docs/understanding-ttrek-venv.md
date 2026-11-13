# Understanding ttrek-venv

Think of each project as having its own toolbox. **`ttrek-venv` is that
toolbox:** it holds the packages and build files that ttrek manages for the
project. `ttrek init` creates it inside your project directory.

With normal project installs, two projects can use different versions of the
same package. Updating one project's packages does not replace the other
project's installed copies.

The main parts look like this:

```text
my-app/
  ttrek.json           # Which packages the project asks for
  ttrek-lock.json      # The versions ttrek selected
  ttrek-venv/
    local/            # Installed programs and libraries
    build/            # Downloads, source files, build files and logs
```

Create a project, install Tcl, and run it with the project's tools:

```sh
mkdir my-app
cd my-app
ttrek init -y
ttrek install tcl@9.1.0
ttrek run tclsh9.1
```

`ttrek run` looks for commands in `ttrek-venv/local/bin` first and sets the
library search path to `ttrek-venv/local/lib`. There is no separate activation
step. Programs still run with your normal permissions and filesystem access.

The shared sources introduced in ttrek 1.3.0 also belong to one project.
Packages within it can reuse files under `ttrek-venv/build/shared-source`;
another project has its own environment.

Keep your application code, databases, and uploads **outside `ttrek-venv`**.
Let ttrek manage the toolbox while you keep your own work alongside it.

See [Getting started](/docs/getting-started) to create your first project.
