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

The detector also retains Rustup targets for which this project has no binary:

| Detected platform | Example request target (unsupported) |
| --- | --- |
| 32-bit Linux x86 | `i686-unknown-linux-gnu`, `i686-unknown-linux-musl` |
| 32-bit Linux ARM | `arm-unknown-linux-gnueabihf`, `armv7-unknown-linux-musleabihf` |
| Other Linux CPUs | `mips-unknown-linux-gnu`, `mipsel-unknown-linux-gnu`, `mips64el-unknown-linux-gnuabi64`, `powerpc64le-unknown-linux-gnu`, `s390x-unknown-linux-gnu`, `riscv64gc-unknown-linux-gnu`, `loongarch64-unknown-linux-gnu` |
| Android | `aarch64-linux-android`, `armv7-linux-androideabi`, `x86_64-linux-android` |
| BSD / illumos | `x86_64-unknown-freebsd`, `x86_64-unknown-netbsd`, `x86_64-unknown-dragonfly`, `x86_64-unknown-illumos` |
| Windows shells (MSYS / MinGW / Cygwin) | `x86_64-pc-windows-gnu` with `/ttrek.exe` |

These requests return 404. They need compatible builds before adding aliases;
CPU-name similarity alone is insufficient. The detector normalizes `amd64`,
`x64`, and `x86-64` to `x86_64`, and `arm64` to `aarch64`. It never automatically
selects universal2. The inherited `--default-host` and `--target` help options
do not override detection. Linux libc detection assumes glibc unless
`ldd --version` reports musl, and only glibc targets currently adjust for a
64-bit kernel with a 32-bit userland.

For Lambda deployment, `devops/config.prod.ini` supplies `[releases]`; the
adapter resolves `checksums_file` from the packaged application root. Deploy the
updated configuration, application ZIP and SAM execution-role policy together.
A 503 from `/dist/<target>/ttrek` means the bucket is unset or signing failed;
an unsupported target returns 404. A successful mapping returns 302, followed by
the client's request to S3. A later S3 403 is a separate object-access failure.
The Lambda execution role needs `s3:GetObject` on the configured prefixes for
those signed URLs to work; see [AWS's presigned URL permissions](https://docs.aws.amazon.com/AmazonS3/latest/userguide/using-presigned-url.html#who-presigned-url).

`checksums_file` is a JSON file resolved relative to the application root (or an
absolute path). The release upload
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

Source archive fallbacks use `GET /download/<recipe>-<version>-<url-sha256>.archive`.
The SHA-256 identifies the exact upstream URL; it is not a content checksum.
A recipe's optional `filename` is URL-encoded in `?filename=...` for JSON logging
only. It never changes the S3 key or the signed URL.

Upload mirrored archives to `<source_prefix>/<recipe>-<version>-<url-sha256>.archive`
in the configured private bucket. These redirects use the same S3 client, with
independent settings:

```ini
[releases]
source_prefix = ttrek/sources
source_url_expiry_seconds = 300
```

Populate this mirror from a registry checkout with:

```sh
# Preview every URL/key mapping without contacting AWS or upstream servers.
bin/upload-archives-to-s3.sh --dry-run

# Check S3, download missing archives, and upload them; keep a log of failures.
AWS_PROFILE=ttrek-prod-neo bin/upload-archives-to-s3.sh 2>&1 | tee upload-archives.log
```

The shell launcher uses `bin/site-env.sh` to select the local `ttrek-venv` Tcl
runtime and libraries, just like the other site launchers. The implementation is
`bin/upload-archives-to-s3.tcl`, using `tjson` for specs and Tcllib's `sha256` for
URL hashes; curl and the AWS CLI handle transfers. `TTREK_SITE_PREFIX` can select
another installation. It defaults to the sibling `ttrek-registry` checkout;
pass another checkout as a positional argument.
It uses the normal AWS credential chain, including `AWS_PROFILE`. The region is
`AWS_REGION`, then `AWS_DEFAULT_REGION`, then `eu-central-1`; `--region` overrides it.
Use `--bucket` and `--prefix` to override `jerily-ttrek-app` and `ttrek/sources`.
The prefix must match the website's `releases.source_prefix`.

The configured fallback location is:

```text
s3://jerily-ttrek-app/ttrek/sources/<package>-<version>-<url-sha256>.archive
```

Package and version come from the `<package>/<version>/ttrek.json` directory
path, as in ttrek's registry resolution. The digest is lowercase hexadecimal
SHA-256 of the exact download URL, with no trailing newline. URLs must use ASCII
(percent-encode other characters); the script neither expands variables nor
hashes the final redirect URL. Download `filename` options do not affect the key.

Every `download` command in every build variant is considered, including
conditional steps and multiple archives per recipe. Duplicate keys are processed
once per run. Git checkouts and recipes without download steps need no mirror.
Existing objects are skipped using `head-object`. Only a missing-object response
triggers a download; permission or connection errors are logged and skipped.
Use credentials with permission to check object existence and upload under the
source prefix, including bucket listing permission so S3 can report missing keys.

Downloads follow redirects and retry transient failures. Failed or empty downloads
are never uploaded, and temporary files are removed after each attempt. Missing
upstream archives, malformed specs, and S3 failures are logged as warnings; the
script continues and prints counts, exiting successfully after a best-effort run.
Invalid arguments or missing prerequisites fail at startup. Dry runs list all
candidate keys without checking whether they already exist.

`url_expiry_seconds` continues to control binary releases. Source redirects
require a signed URL, use `Cache-Control: no-store`, and return 503 if disabled
or signing fails. The endpoint neither fetches upstream URLs nor populates S3;
missing mirrored objects return S3's error after the redirect.

`aws-sdk-tcl-s3` ^1.0.14 is the direct AWS dependency, using AWS SDK C++
1.11.924. KMS/SSM are supplied by `tconfig`; the session backend supplies
DynamoDB. The registry dependency graph does not install the SDK umbrellas. `build.sh` builds 1.0.12 against SDK C++ 1.11.921 and upgrades older
installed SDK modules and bindings. Each worker lazily creates an S3 client
using the configured region and the SDK's default credential provider. Configure
an AWS profile/environment locally or the Lambda execution role in production with
`s3:GetObject` on the release prefix. No credentials go in the release settings.
The `jerily-ttrek-app` bucket remains private; download clients receive temporary
access through signed URLs. The infrastructure declares private bucket access
and grants the application task role object-read permissions. The signer needs
valid AWS credentials. See AWS's
[presigned URL documentation](https://docs.aws.amazon.com/AmazonS3/latest/userguide/using-presigned-url.html).
