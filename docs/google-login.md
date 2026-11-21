# Google Login for local development and production

The account UI uses `web-user` 0.7.0 and `pure-tcl-oauth2-client`. Install the new
core/client packages and updated native dependencies (`tjson` 1.0.30,
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
`devops/config.prod.ini` enables Google Login and leaves credentials and the
redirect URI empty for SSM to supply.

Create a Google Cloud OAuth client of type **Web application**, configure the
consent branding/audience, and add test users if the application is in testing.
Register **http://localhost:8080/user/google/callback** exactly as an authorized
redirect. Use `localhost`, not `127.0.0.1`, in the browser for this configuration.
If you change the port or account prefix, change both the site origin/callback and
the Google registration. Use the client ID and secret from that same OAuth client.
See [Google's setup instructions](https://developers.google.com/identity/openid-connect/openid-connect).

For production, set these SSM parameters and register the HTTPS callback in Google:

- `/ttrek_sh/prod/account/google_client_id`: the production OAuth client ID.
- `/ttrek_sh/prod/account/google_client_secret`: its client secret, as SecureString.
- `/ttrek_sh/prod/account/google_redirect_uri`: `https://ttrek.sh/user/google/callback`.

The configuration adapter passes
the secret to the mount's `-secret_config`, never to display properties.

Production also requires outbound HTTPS. Before redirecting the browser, the
OAuth client fetches Google's discovery document; the callback exchanges the
code and fetches signing keys. A VPC with only AWS interface endpoints cannot
reach these Google services and returns `Google sign-in could not start`.
The base network template supplies one NAT gateway and reuses the Lambda TCP 443
egress rule already owned by the RDS stack.
See [the two-stage network migration](deployment.md#google-login-network-migration)
to establish NAT before removing the four paid AWS interface endpoints.
This network fix does not require changing account keys or rebuilding Lambda.

The route manifest includes `GET/HEAD /user/google/link`, `POST /user/google/start`,
`GET /user/google/callback` and `POST /user/google/unlink`. Regenerate the API Gateway template with
`ttrek run -package tdevops -script generate-api-gateway` after changing routes. It writes
`dist/api-gateway.json` and `devops/infra/40-api-gateway.json`; deploy the updated
template through `devops/infra/40-deploy-api-gateway.sh` with the application release.

The button requests `openid email profile`. Verified issuer and subject identify
the account; matching email alone never links an existing account. Existing users
sign in normally and choose “Link Google account” on their account page. The
separate `/user/google/link` page asks for their current password before starting
the Google flow. New Google accounts can operate without a password, retain
local MFA requirements, and can
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
