# Registries

## Public registry

```sh
ttrek sync
```

This creates or updates the public registry at `~/.local/ttrek-registry`. Existing
checkouts must be clean and on `main`; sync uses a fast-forward update.

Registry lookup uses explicit command options, then the project's saved sources,
then the synced public registry, then the public HTTP API.

## Private packages with public dependencies

```sh
ttrek install -y -registry ../private-ttrek-registry -add-pubreg web-wiki
```

`-add-pubreg` appends the public source after the private registry. The lockfile
saves the public source symbolically, so it does not depend on another machine's
home directory. Git still needs access to any private package source repositories.

The first registry containing a package supplies all of its versions and its
recipe. Only an absent package advances to the next source; a malformed recipe
or access error stops lookup.

## Work with a local recipe checkout

```sh
ttrek install -y -registry /path/to/ttrek-registry
ttrek gen-script -registry /path/to/ttrek-registry > build.sh
```

Each recipe lives at `PACKAGE/VERSION/ttrek.json`. Its dependency constraints
and ordered build steps describe how to install that version. Relative registry
paths saved in the lockfile resolve from the project directory.
