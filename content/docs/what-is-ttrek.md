# What is ttrek?

**ttrek is a package manager for C and Tcl packages.** A package is a piece of
software you can reuse, such as a library that helps your app read data or
connect to a database.

Think of building an app like building with blocks. You choose the blocks you
need, and ttrek gets them ready to use. If one block needs another, ttrek gets
that too. Those extra pieces are called **dependencies**.

ttrek downloads the source code, follows build instructions called recipes,
and installs the packages. It also keeps track of versions and helps you
update them.

For example, inside a project you have created with `ttrek init`:

```sh
ttrek install tcl tjson
```

This installs Tcl, which runs Tcl programs, and `tjson`, which helps those
programs read and write JSON data.

Each project keeps its packages in its own
[ttrek-venv directory](/docs/ttrek-venv). That lets two projects use different
versions without replacing each other's packages.

Follow [Getting started](/docs/getting-started) to install ttrek and create
your first project.
