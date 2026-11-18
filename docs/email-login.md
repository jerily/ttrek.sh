# Email-code sign-in

The account login page shows Google (when enabled), “Email me a one-time code”,
an OR divider, then the email/password form. The email option opens a separate
form. Existing active accounts sign in with their password and profile unchanged;
a successful code check also verifies their email. New visitors get a verified,
passwordless account when they confirm the code. Names can be added later through
Profile. MFA remains required for users who enabled it.

Both configuration templates enable `account.email_login_enabled=true`.
Production queues all account emails, including new-account codes, in the same
SQS queue. The existing email worker sends them through SES and handles retries
and expired codes. Delivery requires
`account.email_enabled=true`. LOCAL displays a development code without sending
mail. No additional secrets are needed.

Use `web-user 0.7.0`. Upgrading from 0.6.2 needs no schema change. New accounts
have no profile row until names are saved; the existing `NOT NULL` name columns
remain valid. For installations older than 0.6.1, run `task_initdb_website` to add
the account activity column. “Manage users” then shows linked providers and
the last completed email-code sign-in. Existing accounts start with no recorded
email-code usage.

The proxy manifest and generated API Gateway template include GET, HEAD and
POST for `/user/email-login` and `/user/email-login/verify`.

`npm run build` includes `public/css/accounts.css` in `site.css` and creates a
standalone fingerprinted `accounts.<hash>.css`. Both are in the asset manifest
and browser-asset upload inventory used by `devops/upload-browser-assets.tcl`
during deployment. The shared page loads `site.css` from its configured CDN
URL. Publish the assets with the application release so the layout is available.
