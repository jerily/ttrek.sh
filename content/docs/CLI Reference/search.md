# ttrek search

Find packages and print their names and descriptions, separated by a tab.

## Usage

```text
ttrek search [-registry SOURCE]... [-add-pubreg] QUERY
```

Matching ignores ASCII case and preserves punctuation. Queries accept 1–255
ASCII letters, digits, spaces, `.`, `_`, `+`, or `-`. Quote phrases such as
`'web server'`. No matches prints nothing and succeeds.

## Ranking and typo matching

Results are ranked in this order:

1. Exact name.
2. Name prefix.
3. Name substring.
4. Literal description.
5. Literal tag.
6. Name typo.
7. Description typo.
8. Tag typo.

Ties prefer fewer edits, greater query-trigram coverage, less unmatched name
text, then alphabetical name.

Name typos use a trie; descriptions and tags use `ttrigrams` with substring
verification. Queries of at most three characters allow one edit; longer
queries allow two. Distances are Levenshtein: insertions, deletions, and
substitutions. Description and tag suggestions require a shared trigram;
queries shorter than three characters match them literally.

## Registries

Search uses an explicit registry, the nearest project's saved registry, or an
existing `~/.local/ttrek-registry`, in that order. When no local public registry
is available, it queries `https://ttrek.sh/registry/search?q=QUERY`. It works
outside a project.

`-registry` accepts directories or HTTP(S) registry API base URLs. Repeat it
to select ordered sources. `-add-pubreg` appends the public default after
explicit or saved sources. HTTP registries must provide
`GET BASE/search?q=QUERY`.

Results from ordered sources are ranked together; an earlier source's package
hides later copies. Descriptions and tags from all versions are indexed, and
each package appears once. Missing descriptions and tags are allowed. Tags
are searched individually. A description hit displays its matching text;
name and tag hits display the first nonempty description in alphabetical order.

## Offline search and side effects

Local indexes are built only for this command. Search never downloads source
archives, creates project state, sends telemetry, or checks for updates. Use
`ttrek sync` to make the public registry available for offline search.
