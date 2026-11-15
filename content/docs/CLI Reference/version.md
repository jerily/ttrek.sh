# ttrek version

Print the executable version, self-update platform (for example,
`linux-amd64-glibc`), telemetry status, `TTREK_DEBUG` status, and debug build status.

## Usage

```sh
ttrek version
```

This command does not contact the network, collect telemetry, or create files.

## Telemetry status

Telemetry is on by default when using the implicit public HTTP registry.
Explicit, saved, and synced local registries disable it.

Set `TTREK_TELEMETRY=0` to disable telemetry everywhere. Leaving it unset or
setting it to `1` preserves the registry policy. Boolean values `true`/`false`,
`yes`/`no`, and `on`/`off` also work. Empty or invalid values disable telemetry.

Disabled telemetry does not load or save a machine ID, collect environment
information, send telemetry events, or add an environment ID header. If registry
settings cannot be read, telemetry status is reported as unknown.

## Debug status

Debug is on when `TTREK_DEBUG` is set, including an empty value or `0`.
Debug build reports whether compile-time debug diagnostics are enabled.

`ttrek self-update -version` continues to print only the version number.
