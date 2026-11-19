# ttrek sync

Clone or refresh a local copy of the public package registry. Requires `git`.

## Usage

```text
ttrek sync [DIRECTORY]
```

By default, clone `https://github.com/jerily/ttrek-registry.git` into
`~/.local/ttrek-registry`. Supply `DIRECTORY` to use another destination, or
`.` for the current directory.

New clones use `--depth 1` to download only the latest commit on `main`
initially. An existing clean `main` checkout is updated with `git pull --ff-only`.
Other repositories, local changes, and divergent history are preserved and
rejected. Custom checkout paths and Git worktrees are supported.

## Registry selection

Registry commands prefer an explicit `-registry` option, then a saved project
registry, then a successfully synced `~/.local/ttrek-registry`, then
`https://ttrek.sh`.

Package search always uses a registry website.

With a single selected local registry, absent packages do not fall back to the
website. Use repeated `-registry` options to select additional sources explicitly.

## Refresh reminders

A sync-managed local registry that has not been synced for 24 hours prints a
reminder to run `ttrek sync`, or `ttrek sync .` for a custom checkout. A checkout
behind its last fetched `origin/main` also warns, even if its sync timestamp is
recent. These checks use local metadata; they do not fetch or contact the network.
Private and unmanaged registries are not told to use the public-registry sync
command.
