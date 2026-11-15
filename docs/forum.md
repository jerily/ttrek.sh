# Forum and access configuration

The site mounts `web-forum` at `/forum`, using the same `web-user` account store
and SQL connection as `/user`. The navigation's Forum link leads there; the logo
still leads to the homepage. Discussion authors link to public forum profiles.

Configure policy in `etc/config.ini` or the deployment configuration:

```ini
[forum]
moderation = true
posting_captcha = true
page_size = 20

[groups]
admin = mira@example.com, rowan@example.com
moderator = alex@example.com

[permissions]
admin = forum.moderate, wiki.edit, blog.edit, users.manage
moderator = forum.moderate
```

`moderation` holds all new topics and replies for approval. `posting_captcha`
requires a session-bound, expiring `tcaptcha` challenge on posting forms. They
are independent switches, both false by default. Account CAPTCHA settings
control challenge length, lifetime and attempt limits. Newest topics is the
default order; readers can choose latest public activity. All lists paginate.

Apply schema through the existing private `task_initdb_website` operation.
Group membership and permission changes are separate: deploy the configuration,
then invoke **`task_sync_access`**. Worker startup and HTTP requests do not sync
access or create schema. The same task is available in the CodeBuild patch
project's `PATCH_TASK` selection.

The `bootstrap-local` script runs schema initialization, access sync, content
sync and tracker refresh in that order. To apply access separately in the local
Lambda stack:

```sh
ttrek run -script initdb-local
ttrek run -script sync-access-local
```

For a deployed Lambda, use the existing private Invoke API/patch pipeline with:

```json
{"source":"ttrek.patch","task":"task_sync_access"}
```

The sync replaces only the account tenant's configured groups and grants in one
transaction. Removing an address or permission and syncing revokes access on
the next request, including existing sessions. Accounts must be active and have
verified emails. You can list an administrator before they register.

`forum.moderate` grants the pending queue, hidden-post list, moderation history,
approve/reject, hide/restore, and lock/unlock actions. Every action requires a
reason and stores moderator ID, time, target and before/after state atomically.
The UI hides controls from ordinary members; the server independently checks
permission, CSRF, origin and revision. Restoring hidden content preserves its
approval state. Hidden or unapproved posts are absent from public lists.

Administrators also receive `users.manage` in the default configuration. After
access sync, **Account → Manage users** shows registered users, registration
times, authenticator status and group assignments. The directory is checked
against current permissions on every request and contains only this account
tenant. Moderator/editor grants alone do not reveal it.
