# Google Login for local development and production

The account UI uses `web-user` 0.6.1 and `pure-tcl-oauth2-client`. Install the new
core/client packages and updated native dependencies (`tjson` 1.0.28,
`tink-tcl` 20240704.0.3, `thashlib` 0.1.1) before starting the site. Run the normal
account schema initialization once to add identity and transaction tables.
Registry recipes pin the package release tags.
Local source packages can also be installed with CMake into the runtime prefix.

`etc/config.ini` and the ignored `etc/config.local.ini` use these explicit LOCAL
placeholders:

```ini
[account]
google_enabled = true
google_client_id = fake-local-client.apps.googleusercontent.com
google_client_secret = fake-local-secret-configure-before-use
google_redirect_uri = http://localhost:8080/user/google/callback
```

The placeholders let the UI and configuration be exercised; they cannot complete
a real Google login. Replace them in the private local configuration when ready.
No environment variables supply these values. The production template
`devops/config.prod.ini` leaves all four Google fields empty, keeping login disabled.

Create a Google Cloud OAuth client of type **Web application**, configure the
consent branding/audience, and add test users if the application is in testing.
Register **http://localhost:8080/user/google/callback** exactly as an authorized
redirect. Use `localhost`, not `127.0.0.1`, in the browser for this configuration.
If you change the port or account prefix, change both the site origin/callback and
the Google registration. Use the client ID and secret from that same OAuth client.
See [Google's setup instructions](https://developers.google.com/identity/openid-connect/openid-connect).

For production supply `account.google_enabled=true`, the production client ID,
its client secret and `https://ttrek.sh/user/google/callback` through the site's
private configuration mechanism; register that HTTPS callback in Google. Keep the
client secret private (for SSM use SecureString at
`/ttrek_sh/prod/account/google_client_secret`). The configuration adapter passes
the secret to the mount's `-secret_config`, never to display properties.

The route manifest includes `POST /user/google/start`, `GET /user/google/callback`
and `POST /user/google/unlink`. Regenerate the API Gateway template with
`python3 devops/generate-api-gateway.py` after changing routes. It writes
`dist/api-gateway.json` and `devops/infra/40-api-gateway.json`; deploy the updated
template through `devops/infra/40-deploy-api-gateway.sh` with the application release.

The button requests `openid email profile`. Verified issuer and subject identify
the account; matching email alone never links an existing account. Existing users
sign in normally and explicitly link Google from their account page. New Google
accounts can operate without a password, retain local MFA requirements, and can
set a password after confirming Google. Unlinking cannot remove the only sign-in
method. The site does not retain Google access or refresh tokens for login.

Mock-provider tests cover these behaviors with locally signed RSA tokens. No real
Google credentials are required or tested during development. To troubleshoot a
real setup, check exact redirects, the chosen OAuth client and consent audience;
keep token verification enabled and exclude callback queries from access logs.

## Private site settings

`::site::init_worker $publicSettings -secret_config $privateSettings` forwards
private settings to `::site::mount`. The dictionary has `account`, `postgres` and
`redis` entries. `account` contains `aead_keyset`, `mac_keyset`, `email_hash_salt`
and `google_client_secret`; `postgres` and `redis` each contain `password`.
The bootstrap partitions loaded INI values before handing configuration to the
server. Neither `::site::config` nor `twebserver::get_config_dict` contains these
secrets. There is no public-password fallback. Direct connection and maintenance
helpers likewise receive `-secret_config {password ...}`.

The site calls `web-user::mount -connection ... -policy ... -config ...
-secret_config ...`. Mount registers the private account keysets and releases
its handles through `::web::user::release`. Account policies and display
properties contain no keysets, salt or Google client secret.
