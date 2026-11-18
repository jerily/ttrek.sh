# Email-code sign-in

The account login page shows Google (when enabled), “Email me a one-time code”,
an OR divider, then the email/password form. The email option opens a separate
form and signs in all existing active accounts, including those with unverified
email. A successful code check verifies their email. MFA remains required for
users who enabled it. New visitors use registration.

Both configuration templates enable `account.email_login_enabled=true`.
Production uses the site's configured email delivery and requires
`account.email_enabled=true`. LOCAL displays a development code without sending
mail. No additional secrets are needed.

Use `web-user 0.6.2` and run `task_initdb_website` before serving this version to
add the account activity column. “Manage users” then shows linked providers and
the last completed email-code sign-in. Existing accounts start with no recorded
email-code usage.

The proxy manifest and generated API Gateway template include GET, HEAD and
POST for `/user/email-login` and `/user/email-login/verify`.

`npm run build` includes `public/css/accounts.css` in `site.css` and creates a
standalone fingerprinted `accounts.<hash>.css`. Both are in the asset manifest
and browser-asset upload inventory used by `devops/upload-browser-assets.tcl`
and `task_sync_website`. The shared page loads `site.css` from its configured CDN
URL. Publish the assets with the application release so the layout is available.
