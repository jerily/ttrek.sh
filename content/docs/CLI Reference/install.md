# ttrek install

Install packages and their dependencies in the selected environment.

## Usage

```text
ttrek install [options] [PACKAGE[@VERSION_RANGE] ...]
```

Without package arguments, `install` resolves both `dependencies` and
`devDependencies`, runs the project's build instructions, and preserves each
dependency's section.

## Options

| Option | Description |
| --- | --- |
| `-registry SOURCE` | Append a local directory or HTTP(S) API URL. Repeat to set lookup order. |
| `-add-pubreg` | Append the public default after explicit or saved sources: the synced local copy, otherwise the API. |
| `-y` | Answer yes to the installation confirmation. |
| `-force` | Reinstall requested packages even when unchanged, plus their transitive reverse dependencies. With no package arguments, target all direct dependencies. |
| `-keep` | Keep package sources, downloads, patches, and build directories after success. |
| `-strategy STRATEGY` | Choose `favored` (default), `latest`, or `locked`. |
| `-fail-verbose` | Show the build log when installation fails. |
| `-save-dev`, `-D` | Save explicitly named packages in `devDependencies`. |
| `-u` | Install in the user environment (`~/.local`). |
| `-g` | Install in the global environment (`/usr/local/ttrek`). |

Without a mode option, packages install in the local project environment
(`./ttrek-venv`).

## Package versions

`PACKAGE` is a package name such as `twebserver`. `VERSION_RANGE` is a
comma-separated list of operator/version pairs.

| Operator | Meaning |
| --- | --- |
| `^` | Accept versions with the same major version. |
| `>=` | Greater than or equal to the specified version. |
| `>` | Greater than the specified version. |
| `<=` | Less than or equal to the specified version. |
| `<` | Less than the specified version. |
| `==` | Equal to the specified version. |

For example:

```sh
ttrek install twebserver@1.47.37
ttrek install twebserver@^1.47.37
ttrek install "twebserver@>=1.47.37,<1.50.0"
```

## Resolution strategies

| Strategy | Behavior |
| --- | --- |
| `favored` | Prefer versions recorded in the lockfile that satisfy the requirements. |
| `latest` | Prefer the newest compatible versions for requested packages. Keep other locked versions when compatible with the requested change. With no package arguments, consider the entire dependency graph. |
| `locked` | Require locked versions for packages already in the lockfile. |

The first registry containing a package supplies its versions and recipe.
Only an absent package advances to the next registry; other errors stop lookup.
Explicit sources replace the saved list and defaults for this invocation.

## Dependencies and rebuilds

`-save-dev` affects only explicitly named packages. It can move an existing
runtime dependency to `devDependencies` without requiring a rebuild. Transitive
packages are not added to either direct-dependency section. A package name must
appear in only one root-project dependency section.

Like npm, ttrek installs both sections for the root project, but follows only
`dependencies` in installed package recipes. Their `devDependencies` are ignored,
even when the package itself is a root development dependency. Transitive
packages share the project prefix and appear in lockfile/manifest `requires`,
not as direct dependencies.

New or changed packages and their transitive reverse dependencies (packages
that depend on them) are installed in dependency order. Unchanged forward
dependencies and unrelated packages are not rebuilt. The `preInstall` and
`postInstall` project hooks run around the install operation.

## Build files and installed state

Successful packages have their private sources, patches, and build directories
removed. Shared sources and downloads are removed once the operation succeeds.
Logs and generated scripts remain. Failed packages keep their sources and build
files; failed operations keep shared caches. `-keep` disables cleanup. No-op and
cancelled operations leave caches. Root project sources and builds are preserved.

The lockfile records resolved versions; it is not proof of installation.
`ttrek-venv/ttrek-manifest.json` records installed versions, files, build flags,
and dependencies. Missing installations or files are rebuilt even when locked.
Older manifests without build metadata are refreshed by reinstalling once.

## Examples

```sh
ttrek install -y twebserver
ttrek install -save-dev cmake
ttrek install -D ninja
ttrek install -force web-wiki
ttrek install -keep twebserver
ttrek install -strategy latest web-blog
```
