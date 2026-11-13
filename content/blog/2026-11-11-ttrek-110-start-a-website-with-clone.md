# ttrek 1.1.0: start a website with clone

**ttrek 1.1.0 is here!** The main addition is `ttrek clone`, a new command that
downloads and unpacks a package's source files into a folder you choose.
That gives you your own copy to explore and change.

Think of an example website as a building kit. It comes with pages, a design,
and instructions for putting the pieces together. With `clone`, you can bring
that kit onto your computer and start making it yours.

There are two example websites to try:

- **A personal site:** a homepage, a journal, and a notebook you can edit in your
  browser.
- **A community site:** a place with accounts, discussions, a shared notebook,
  and a journal.

To try the personal site, first follow [Getting started](/docs/getting-started)
to install ttrek and the build tools. Use ttrek 1.1.0 or newer, then open a
terminal and run these commands one at a time:

```sh
ttrek clone example-personal-site -outdir my-personal-site
cd my-personal-site
ttrek install -y
ttrek run -script start
```

`clone` gets the files. `-outdir` names their new home; choose a new or empty
folder. `cd` moves you into that folder. `install` gets the other packages the
website needs, and `-y` accepts the installation plan. Finally, `run` starts
the website. The first installation can take a while as some packages need
to be built on your computer.

Open **http://localhost:8080** in your browser and leave the terminal running.
`localhost` means "this computer." Your example is running locally, ready for
you to explore. Click **Notebook**, then **New page**, and write something!
Keep the personal example on localhost: it lets you edit without signing in.
Press **Ctrl-C** in the terminal when you want to stop it.

Ready to change the homepage or try the community site? Follow
[Build websites with ttrek](https://ttrek.sh/docs/build-websites-with-ttrek).
The guide walks through both examples with screenshots, from your first page
to creating an account and posting a discussion.
