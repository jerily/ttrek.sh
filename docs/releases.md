# Binary distributions

[Documentation](readme.md) · [Project overview](../README.md)

This guide covers serving ttrek downloads from the website. To prepare and
upload the executables, see the CLI's
[release guide](https://github.com/jerily/ttrek/blob/main/docs/releases.md).
Configuration paths below are relative to the website checkout.

`GET /dist/<target>/ttrek` redirects to a signed HTTPS S3 GET URL. Configure the
private distribution bucket in `[releases]` in `etc/config.local.ini` for LOCAL
mode, or the production configuration. Empty `bucket` disables downloads with
HTTP 503; it does not affect registry routes. The tracked template and local
configuration contain the same release settings:

```ini
[releases]
bucket = jerily-ttrek-app
region = eu-central-1
prefix = ttrek/1.0.0
version = 1.0.0
url_expiry_seconds = 300
checksums_file = etc/releases.json
```

The [portable release build](https://github.com/jerily/ttrek/pull/33) exports
`dist/<target>/ttrek`. Upload each executable to `<prefix>/<target>/ttrek` in the
configured bucket, using these target names:

| Target | Installer alias |
| --- | --- |
| `linux-amd64-glibc` | `x86_64-unknown-linux-gnu` |
| `linux-arm64-glibc` | `aarch64-unknown-linux-gnu` |
| `linux-amd64-musl` | `x86_64-unknown-linux-musl` |
| `linux-arm64-musl` | `aarch64-unknown-linux-musl` |
| `macos-arm64` | `aarch64-apple-darwin` |
| `macos-x86_64` | `x86_64-apple-darwin` |
| `macos-universal2` (optional) | `universal2-apple-darwin` |

For example, `/dist/linux-arm64-musl/ttrek` and
`/dist/aarch64-unknown-linux-musl/ttrek` select the same object. The existing
installer follows the redirect. Unknown targets and extensions return 404.
`public/ttrek-init` defaults to `https://ttrek.sh`, detects Linux libc and CPU,
and selects native ARM64 on Apple Silicon even under Rosetta. Intel Macs retain
the Intel target. Curl and wget verify certificates and follow the S3 redirect.
With `ENV=LOCAL`, it defaults to `http://localhost:8080`; the LOCAL homepage's
install command passes that environment setting into the script. To use local
HTTPS, set `TTREK_UPDATE_ROOT=https://localhost:4433` and trust the local certificate
through the downloader's CA configuration.

`checksums_file` is a JSON file resolved relative to the application root (or an
absolute path). The tracked `etc/releases.json` starts empty; the release upload
script in the sibling `ttrek` checkout merges SHA-256 hashes into it after all
selected uploads succeed. Its structure is environment → version → target → hash:

```json
{
  "local": {},
  "prod": {
    "1.0.0": {
      "linux-amd64-glibc": "<64-character SHA-256 of the executable>"
    }
  }
}
```

The placeholder above illustrates the structure; real entries require a valid
64-character hexadecimal digest. `ENV=LOCAL` selects `local`; production selects
`prod`. `releases.version` selects the exact version in that section. Missing
versions or targets have no checksum; malformed JSON, invalid entries, and
missing configured files fail startup. Inline `sha256_<target>` settings are
replaced by this manifest.

From the `ttrek` checkout, run `ttrek run -script upload-local -- 1.0.0` or
`ttrek run -script upload-prod -- 1.0.0`; optionally append target names.
The script defaults to this checkout's `etc/releases.json` when the repositories
are siblings. Otherwise set `TTREK_CHECKSUMS_FILE` to the configured file.
It preserves previous versions and targets and rejects changed bytes for an
already recorded production version/target. Run uploads sequentially and commit
the resulting manifest with the configuration change.

`GET /releases/latest/<target>` returns JSON with
`version`, canonical `target`, `sha256`, and a signed `url` for `ttrek self-update`.
It returns 503 if the bucket or that checksum is missing. Use an immutable prefix
per release and update the version and prefix together after uploading. Ship the
manifest with the configuration; the production build already packages `etc/`.
Both endpoints send `Cache-Control: no-store` so cached redirects cannot outlive
their signatures. Restart the application after changing configuration or hashes.
The local mock stack reads the same INI reference and `local` section at startup,
using its `ttrek-local` bucket. Packaged 1.0.0 seed binaries supply hashes only for
targets without uploaded metadata; uploaded hashes take precedence. Repackage
after runtime code changes, and restart the local stack after uploads.
Local uploads also update the S3 seed directory (`dist/s3` here by default),
because the mock's object database is disposable. Packaging preserves existing
release seed binaries; remove a seed explicitly to refresh it from the host CLI.

`aws-sdk-tcl` ^1.0.12 is a direct dependency, using AWS SDK C++ ^1.11.921 in the
registry. `build.sh` builds 1.0.12 against SDK C++ 1.11.921 and upgrades older
installed SDK modules and bindings. Each worker lazily creates an S3 client
using the configured region and the SDK's default credential provider. Configure
an AWS profile/environment locally or an ECS task role in production with
`s3:GetObject` on the release prefix. No credentials go in the release settings.
The `jerily-ttrek-app` bucket remains private; download clients receive temporary
access through signed URLs. The infrastructure declares private bucket access
and grants the application task role object-read permissions. The signer needs
valid AWS credentials. See AWS's
[presigned URL documentation](https://docs.aws.amazon.com/AmazonS3/latest/userguide/using-presigned-url.html).
