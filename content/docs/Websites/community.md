# Build a community website with ttrek

![Neighbors sharing ideas in a garden and workshop, connected through a community website](images/websites/community.png)

A community website gives people a place to meet between meetings. Members can
ask questions, share useful notes, and tell everyone what is happening next.
`example-community` gives you those pieces in a working site you can copy and
make your own.

The example is called **Juniper Yard**, a fictional neighborhood garden and
workshop. You can turn it into a home for a club, a project, a local group, or
people who share an interest. It includes accounts, discussions, a shared
notebook, and a journal.

For a simpler first project, try [the personal site](/docs/websites/personal-site).
This guide adds the next step: letting people sign in and contribute. You will
run everything on your computer, create a test account, and try the site as both
a visitor and a member.

## 1. Get your tools ready

You need a terminal, a text editor, a browser, and ttrek.
Follow [Getting started](/docs/getting-started) to install ttrek and the build
tools. Package installation needs an internet connection, and the first run
can take a while as dependencies are built.

## 2. Clone the example

Open a terminal in the folder where you keep your projects:

```sh
ttrek clone example-community -outdir my-community
cd my-community
```

`clone` gives you your own copy of the example's files. `-outdir` names its new
folder; choose a new or empty folder. You can change this copy without changing
the original example.

The project includes `ttrek.json`, which lists the packages it needs and the
command that starts the website.

## 3. Install and run locally

From `my-community`, run:

```sh
ttrek install -y
ttrek run -script start -- --port 8081
```

`install` gets the packages listed in `ttrek.json`. `-y` accepts the installation
plan. The start command runs `start.sh`, and `--port 8081` chooses the numbered
door where the server listens. The `--` separates ttrek's options from the
options passed to the site.

Open **http://localhost:8081**. `localhost` means “this computer.” Leave the
terminal running while you use the website. Stop the server with **Ctrl-C**;
start it again with the same command.

![Juniper Yard homepage with links to discussions, the notebook, and the journal](images/build-websites/community-home.png)

*Juniper Yard is the sample community. Its accounts and discussions work, ready
for you to try them.*

The example starts in **LOCAL** mode. It creates a SQLite database, a file that
holds the site's records, and shows verification codes in your browser. You can
follow this walkthrough without an AWS account or an email service.

## 4. Create an account and sign in

An account gives your contributions a name. Registration creates the account;
signing in lets the website recognize you on later visits.

### Create your account

Click **Come on in**, then **Create an account**. Enter an email address, first
name, last name, and a password. For this local exercise, use fictional details
such as `mira@example.com`, Mira Fern, and a password you use only for this demo.
Your first name is the public name shown beside your posts.

Click **Create account**. The next screen asks you to verify your email address.

### Enter the verification code

Copy the **LOCAL development code** shown on your screen into **Code**, then
click **Verify email**. Use the code from your own browser session.

On a live site, this step checks that someone can receive mail at the address
they supplied. LOCAL mode puts the code on the page so you can try the whole
flow without sending email.

### Sign in

Enter the same email address and password on the sign-in form and click
**Sign in**. **Stay signed in** keeps the session on that device for later
visits; leave it unchecked on a shared computer.

The account page confirms that you are signed in, and the navigation changes
to **Your account**. The browser keeps a session cookie, like a small pass that
lets the site recognize you as you move between pages.

From **Your account**, you can change your password, edit your profile, and set
up an authenticator app. Start by exploring the community before changing those
settings.

## 5. Start a conversation

Click **The forum**, then **Start a discussion**. Give it a useful title, such
as `What should we make at our first meetup?`, and write a short message:

```markdown
I would like to start with something small that we can finish together.

- Repair a simple household item
- Plant a box of herbs
- Share a favorite tool

What would you like to try?
```

Click **Post**. Your discussion appears with your public name beside it. Add a
reply beneath it to try the conversation flow.

![A community discussion with a member's name and a reply editor](images/build-websites/community-discussion.png)

*A discussion keeps a question and its replies together, so the next person can
join without needing to catch up on a separate chat.*

Markdown is plain text with a little formatting. `**words**` makes words bold,
and a line beginning with `-` becomes a list item. You can use the editor's
visual controls or write Markdown directly.

## 6. Add something useful to the notebook

A discussion is for a conversation. The notebook is for information people will
want to find again: how to join a meeting, where shared tools live, or how to
complete a task.

First, give your account permission to edit. In `config.ini`, set `editor` in
the existing groups and permissions sections, using the email you verified:

```ini
[groups]
editor = mira@example.com

[permissions]
editor = wiki.edit, blog.edit
```

Restart the site. `wiki.edit` lets you create and edit notebook pages, including
the homepage. `blog.edit` does the same for journal posts. You can give someone
just one of these permissions. Signing in alone does not grant editing access.

Click **Our notebook**, then **New page**. Enter `First meetup` as the title and
add:

```markdown
# First meetup

Everyone is welcome. Bring one idea and something you would like to learn.

## Before we meet

- Introduce yourself in the forum
- Suggest a small activity
- Read the community handbook
```

Click **Publish page**. Here, publishing saves the page on your local community
site. Other members with `wiki.edit` can help improve notebook pages too.

Open the page again, choose **Edit**, make a small change, and click
**Publish revision**. The page updates immediately. **Revision history** lets
you see how the writing has changed.

Use **Journal → New post** for dated updates, such as a meetup announcement or
notes from a finished project. Enter a title, publication date, and text, then
click **Publish post**.

## 7. Try the site as a visitor

Choose **Your account → Sign out**. The navigation returns to **Come on in**.
You can still read the discussions, notebook, and journal. Posting in the forum
requires signing in; editing the notebook or journal also requires its permission.

This is an easy way to check your site's two experiences: what a visitor can
read, and what a member can contribute. Sign back in to continue making changes.

## 8. Make the community yours

Start with the name. Open `config.ini` and change `site_name` under `[site]`:

```ini
[site]
site_name = Saturday Makers
```

Edit that setting in the existing file, keeping the other settings in place.
Stop and restart the server, then refresh your browser. The new name appears
in the shared layout.

Next, sign in, open the homepage, and choose **Edit this page**. Keep its title
for your first edit and replace the sample paragraphs with a welcome to your
group. Save the revision and return to the homepage to see your words.

| File or part of the site | Think of it as | What to change |
| --- | --- | --- |
| `config.ini` | The site's settings | Community name and account preferences |
| `assets/page.html.jinja` | A frame around every page | Navigation, footer, and the short tagline |
| `assets/home.html.jinja` | The homepage layout | Placement of the illustration and welcome text |
| `assets/site.css` | The paint and spacing | Colors, fonts, and layout details |
| The notebook and journal editors | Shared writing desks | Pages and posts |
| `content/wiki/` and `content/blog/` | Starter writing | The content shipped with your copy |

Keep template expressions such as `{{ site_name }}` intact: they are places
where the site inserts information. Change one thing at a time and check the
result in your browser.

The packages divide the work: `web-user` handles accounts, `web-forum` handles
discussions, and `web-wiki` and `web-blog` handle shared writing. Your project
brings them together under one design.

### Share pictures

Copy images into `content/images/`. For a file named `garden.jpg`, write:

```markdown
![Our newly planted garden](garden.jpg)
```

This works in the notebook, journal, homepage and forum. Restart after adding
image files, then use the filename in your writing. The site turns it into an
`/images/...` address and serves the picture locally. Image references start
from the image folder even when the page itself is in a subfolder.

### Choose your moderators

Groups are lists of people. Permissions describe what those people may do.
Add the following to your configuration, using your own account emails:

```ini
[groups]
admin = mira@example.com, rowan@example.com
moderator = alex@example.com

[permissions]
admin = forum.moderate, wiki.edit, blog.edit
moderator = forum.moderate
```

Restart the site. Each listed person receives the group's permissions after
verifying their email. You can set up the list before they register. To remove
access, remove their address and restart. The name `admin` does not grant
anything by itself: the permissions line does.

The moderator group can manage discussions. It needs `wiki.edit` or `blog.edit`
added to its permission list to edit notebook pages or journal posts as well.

A moderator sees **Pending moderation**, **Hidden posts**, and **Moderation
history** in the forum. They can hide and restore posts, or lock a discussion to
close it to new replies. Every action asks for a reason and records who acted
and when, so the team can understand the decision later.

To review new posts before anyone else sees them, set:

```ini
[forum]
moderation = true
```

Restart, then submit a topic or reply. Its author can see that it is waiting;
a moderator can approve or reject it from the pending queue. This applies to
all new submissions. Hiding and restoring a post is separate from approving it.

You can also turn on a small image challenge before posting:

```ini
[forum]
posting_captcha = true
```

The form asks the person to type the characters shown in the image. It applies
to both new discussions and replies. Both settings are off in the starting
example, so you can try ordinary posting first.

The discussion list starts with **Newest topics**. Choose **Latest activity** to
find conversations with recent visible replies. Use **Next** and **Previous** to
move between pages, and click an author's name to visit their forum profile.

## 9. Keep your community's work

Stop the server, start it again, and return to your discussion. Your account,
posts, and browser edits remain saved.

Two local files matter:

| File | What it holds |
| --- | --- |
| `data/community.sqlite3` | Accounts, sessions, discussions, pages, and posts |
| `data/community.keyset` | Keys used to protect private account information |

The database is like a filing cabinet; the keyset unlocks its protected records.
Keep both when backing up the site. Stop the local server before copying them,
and store the keys securely alongside your backup plan.

Browser edits are saved in the database. Restarting with unchanged starter files
preserves them. Editing a file in `content/` imports that file's new text on the
next start, so use the browser editors for ongoing community writing.

Before inviting people to create real accounts, give the site its own email
salt. This is a private random value used when looking up account email
addresses. Generate it once:

```sh
openssl rand -hex 32
```

Save the result in a private `site.ini`:

```ini
[account]
email_hash_salt = PASTE_THE_GENERATED_VALUE_HERE
```

Start with that configuration:

```sh
ttrek run -script start -- --port 8081 --config site.ini
```

Choose this value before creating the accounts you intend to keep, then reuse
it across restarts and include it in your backup plan. Treat the account created
earlier in this walkthrough as a disposable practice account.

## 10. Prepare for AWS deployment

Install the [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html),
then configure your access key ID and secret access key in a named profile:

```sh
aws configure --profile community-site
aws sts get-caller-identity --profile community-site
```

Enter your intended AWS region and `json` as the output format at the prompts.
Check the returned `Account` and `Arn` to confirm the profile uses the intended
identity. Keep credentials in the AWS profile, outside the project files.
See [AWS profiles](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-files.html)
and [checking your identity](https://docs.aws.amazon.com/cli/latest/reference/sts/get-caller-identity.html).

The next installment will cover putting the community online with HTTPS,
PostgreSQL, email delivery, and persistent keys. For now, the site runs on your
computer and the AWS profile is prepared for the deployment steps.

## If something gets stuck

| What you see | What to try |
| --- | --- |
| The destination is not empty | Choose a different `-outdir` name or an empty directory. |
| A missing build tool | Install the named tool, then rerun `ttrek install -y`. |
| “Address already in use” | Choose another port, such as `--port 8082`, and open the matching URL. |
| The browser cannot connect | Keep the start command running and open the local URL it prints. |
| Startup asks for production settings | Run `unset ENV` in your local-demo terminal, then start again. |
| A verification code is rejected | Use the current code displayed in your own LOCAL session. |
| The sign-in form shows an image challenge | Enter the characters shown and submit the form again. |
| Editing controls are missing | Sign in through **Come on in**. |
| The new community name does not appear | Save `config.ini`, stop and restart the server, then refresh. |
