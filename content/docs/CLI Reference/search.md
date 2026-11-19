# ttrek search

Find packages and print their names and descriptions, separated by a tab.

## Usage

```text
ttrek search [-registry URL]... [-add-pubreg] QUERY
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

On ttrek.sh, queries of at most three characters allow one edit; longer
queries allow two. Distances are Levenshtein: insertions, deletions, and
substitutions. Description and tag suggestions require a shared trigram;
queries shorter than three characters match them literally.

## Registries

Search queries registry websites and works outside a project. Pass an HTTP(S)
registry API base URL with `-registry`, or use the nearest project's saved registry
list. An explicit `-registry` must support the search API. A directory argument
produces an error. Explicit URLs replace the saved list. Search skips directory
entries in the saved list.
When the list has no website, it queries `https://ttrek.sh/registry/search?q=QUERY`,
including when a public checkout has been synced.

Repeat `-registry` to search multiple websites. Each must provide
`GET BASE/search?q=QUERY`. `-add-pubreg` appends the public website. Results are
ranked together, with earlier websites taking precedence for duplicate packages.

Results include language labels in brackets when available, for example
`tjson [C, TCL]`. Search reads registry metadata without creating project state,
sending telemetry, or checking for updates.
