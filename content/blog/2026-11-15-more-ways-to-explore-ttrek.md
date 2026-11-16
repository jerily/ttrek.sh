# More ways to learn, build, and explore on ttrek.sh

![An open guide, conversation bubbles, a package with an activity chart, and a magnifying glass over a package list.](images/website-updates.png)

**ttrek.sh has grown: new documentation, a community forum, a Package Tracker,
and programming-language filters make it easier to find your next step.**
Whether you are installing your first package, starting a website, or following
what is happening in the registry, there is more to explore.

## Documentation for the next thing you want to do

The new [CLI Reference](/docs/cli-reference) brings ttrek's commands into one
place, with usage, options, and examples. Look up `install` and `update`, learn
how `clone` works, or check the details of `run`, project scripts, and
`self-update`. You can still get help directly in your terminal:

```sh
ttrek help
ttrek help install
```

The new [Websites section](/docs/websites) offers illustrated guides for two
complete starting points:

- **[Your first personal website](/docs/websites/personal-site):** clone a
  homepage, journal, and notebook, then make them yours by editing Markdown
  files. Local development needs no user accounts or site database.
- **[Your first community website](/docs/websites/community):** start a place
  with accounts, discussions, a shared notebook, and a journal. Follow the
  screenshots to try the site, customize it, and explore member and moderator
  workflows.

We have also refreshed [Build websites with ttrek](/docs/build-websites-with-ttrek)
to help you choose an example and understand the steps: clone, install, start,
and customize. [Getting started](/docs/getting-started) now connects installation,
build tools, command help, and a first Tcl project with those website guides.

For a closer look at what happens under the hood, the expanded
[ttrek-venv guide](/docs/understanding-ttrek-venv) explains where installed
packages, build files, and logs live. The new
[database persistence tutorial](/docs/database-persistence-layer) walks through
a small task list using tpersist, a JSON schema, and SQLite, with a path to
PostgreSQL. Code examples throughout the docs have clearer styling too.

## A forum for questions and projects

There is now a [community forum](/forum) on ttrek.sh. Browse discussions,
create an account and sign in to start a topic, or reply to someone else's
question. It is a place to share what you are building, ask about a package,
and talk through ideas with other Tcl developers.

Discussions link to their authors' public forum profiles, and you can choose
between the newest topics and those with the latest activity. The forum also
includes moderation tools to help keep conversations useful as the community
grows.

## See what is happening in the registry

The new [Package Tracker](/packages/tracker) gives you four ways to discover
packages, with up to five entries in each group:

| View | What it shows |
| --- | --- |
| **New** | Packages first added to the public registry in the last 30 days. |
| **Recently Updated** | Existing packages with a newly published version in the last 30 days. |
| **Popular** | Packages ranked by unique recipe downloads over the last 30 days. |
| **Trending** | Growth in unique recipe downloads over the last seven days compared with the preceding seven. |

The download rankings count machines requesting package recipes, including
dependencies, and deduplicate repeat requests within each period. Trending
appears once there is enough history and activity for a useful comparison.
The tracker's **How these measures work** panel explains the details, including
the initial estimates used for older publication dates.

A compact tracker summary also appears on the [package listing](/packages)
when activity data is available. Individual package pages now show recipe
download totals by platform and, when enough activity has accumulated, daily
charts. Dependencies link to their package pages, so you can follow the pieces
that make up a project.

## Find packages by programming language

The package search now has a **Programming language** filter. Choose **Only
TCL**, **TCL and C/C++**, or **Only C or C++**, or leave it on **Any** to browse
everything.

For example, open [Only TCL packages](/packages?language=tcl-only) to see
packages whose recipe metadata lists TCL without C or C++. Add a search term
to narrow that list further. The selected filter also applies to search
suggestions, and package pages display the programming languages recorded in
their recipes.

## Easier to browse, lighter to load

The [homepage](/) now highlights website examples, getting started, the latest
blog post, and featured packages in a compact carousel. Package navigation has
also received improvements for smaller screens.

We have reduced the large illustrations used by the website guides, policy
pages, and recent blog posts to under 200 KB each, including the image at the
top of this post. The full-size originals are kept in the source repository.

Try a guide, find a package, or [join the conversation](/forum). We would love
to hear what you build with ttrek.
