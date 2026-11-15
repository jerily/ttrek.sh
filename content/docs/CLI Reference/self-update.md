# ttrek self-update

Fetch the latest ttrek binary for the current executable's platform from
`https://ttrek.sh`. To update packages, use [ttrek update](/docs/cli-reference/update).

## Usage

```text
ttrek self-update [-check|-version]
```

| Option | Description |
| --- | --- |
| `-check` | Check for a newer version without installing it. |
| `-version` | Print the current executable's version without network access. |

Use `ttrek version` to also show the platform and telemetry/debug status.

## Replacing the executable

ttrek verifies the download's SHA-256 and reported version, then atomically
replaces the running executable. Symlinks retain their target. The installation
directory must be writable; no privilege escalation is attempted. Explicit
`self-update` reports download failures and preserves the existing executable.

For local development, `ENV=LOCAL` uses `http://localhost:8080` for the release
metadata endpoint.

## Automatic update checks

Successful interactive commands check for new versions at most daily, with a
one-second timeout. Errors are ignored and notices go to standard error.
Set `TTREK_NO_UPDATE_CHECK=1` to disable automatic checks.
