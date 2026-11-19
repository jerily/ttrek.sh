# Command-line overview

Use this reference to look up ttrek commands, options, and examples. You can
also read help in your terminal:

```sh
ttrek help
ttrek help install
```

Running `ttrek` without a command shows the general help. Use
`ttrek help COMMAND` for a specific command.

## Usage

```text
ttrek [-registry SOURCE]... [-add-pubreg] COMMAND [options]
```

In these usage summaries, square brackets mark optional arguments, `...`
means an argument can be repeated, and `|` separates alternatives.

## Commands

| Command | Description |
| --- | --- |
| [init](/docs/cli-reference/init) | Create a project and its environment. |
| [clone](/docs/cli-reference/clone) | Download and unpack a package's source archive. |
| [install](/docs/cli-reference/install) | Install packages and their dependencies. |
| [pretend](/docs/cli-reference/pretend) | Preview the installation plan. |
| [gen-script](/docs/cli-reference/gen-script) | Generate a standalone build script. |
| [update](/docs/cli-reference/update) | Update project dependencies. |
| [sync](/docs/cli-reference/sync) | Create or refresh a local public registry. |
| [self-update](/docs/cli-reference/self-update) | Update the ttrek executable. |
| [version](/docs/cli-reference/version) | Show the version, platform, and diagnostic settings. |
| [uninstall](/docs/cli-reference/uninstall) | Remove packages and their dependants. |
| [ls](/docs/cli-reference/ls) | List packages recorded in the lockfile. |
| [search](/docs/cli-reference/search) | Find packages by name, description, or tag. |
| [run](/docs/cli-reference/run) | Run a command or named script in the project environment. |
| [activate](/docs/cli-reference/activate) | Open Bash or Zsh with the installed environment and a `(ttrek)` prompt. |
| [scripts](/docs/cli-reference/scripts) | List, inspect, add, or remove named scripts. |
| [use-flags](/docs/cli-reference/use-flags) | Configure USE flags for an installation. |

## Registry options

`-registry SOURCE` accepts a directory or an HTTP(S) registry API base URL.
Repeat it to search sources in order. Registry directories contain
`package/version/ttrek.json` files and adjacent `.diff` patches. Source downloads
still use the URLs in the recipes.

The first source containing a package supplies all its versions and recipes.
Only an absent package advances to the next source; other errors stop lookup.
Explicit sources replace the saved list and defaults for that invocation.

These options also work after `init`, `install`, `update`, `pretend`,
`gen-script`, `clone`, or `search`. `init` saves the ordered list in
`ttrek-lock.json`; the other commands use it for that invocation. Relative
saved paths resolve from the project directory.

`-add-pubreg` appends the public default after explicit or saved sources,
regardless of option placement. It uses the synced `~/.local/ttrek-registry`
when available, otherwise `https://ttrek.sh/registry`. `init` saves this as a
portable public entry. For `search`, the public entry always uses the website.
For `search`, each explicit `-registry` must be an HTTP(S) API base URL.
Search skips saved directory entries and defaults to ttrek.sh when no website is selected.

With no explicit or saved sources, ttrek uses `~/.local/ttrek-registry` after a
successful `ttrek sync`, otherwise the ttrek.sh website. Normal commands do
not create or clone this directory.

## Diagnostics and telemetry

Set `TTREK_DEBUG` to show internal commit IDs, reset details, and individual
file operations. Set `TTREK_TELEMETRY=0` to disable telemetry. Run
`ttrek version` to see the executable version, self-update platform, and
telemetry/debug status.
