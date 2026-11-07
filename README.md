# ttrek.sh

ttrek.sh is the website and package catalog for
[ttrek](https://github.com/jerily/ttrek), the Tcl package manager. Think of it as
a library of building blocks: you find the packages you need, and the catalog
tells ttrek how to download and build them.

Visit [ttrek.sh](https://ttrek.sh) to browse packages, download ttrek, and read
guides and blog posts.

This project is under active development.

## Run locally

Follow the [setup guide](docs/install.md) first. It covers the required tools
and access to private development packages. Once setup is complete:

```sh
ttrek run -script package -- --local-only
ttrek run -script start-local
```

Open <http://127.0.0.1:8080/> to try the website. Press Ctrl-C to stop it.

## Learn more

- [Local development](docs/local-development.md): edit content and run the website.
- [Package registry](docs/registry.md): manage the package catalog and search.
- [All documentation](docs/readme.md): setup, testing, releases, deployment and security.
