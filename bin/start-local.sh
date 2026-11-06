#!/usr/bin/env bash
set -eu
SITE_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
for argument in "$@"; do
    if [[ "$argument" == --help || "$argument" == -h ]]; then
        exec "$SITE_ROOT/bin/start-lambda.sh" --help
    fi
done

children=()
cleanup() {
    trap '' INT TERM
    if ((${#children[@]})); then
        # Stop ingress before the runtime, so the proxy can finish its active
        # invocations while the Lambda service and workers are still available.
        for ((index=${#children[@]}-1; index>=0; index--)); do
            child=${children[index]}
            kill -TERM "$child" 2>/dev/null || true
            wait "$child" 2>/dev/null || true
        done
    fi
}
trap cleanup EXIT
trap 'exit 0' INT TERM
"$SITE_ROOT/bin/start-s3.sh" "$@" &
children+=("$!")
"$SITE_ROOT/bin/start-lambda.sh" "$@" &
children+=("$!")
"$SITE_ROOT/bin/start-proxy.sh" "$@" &
children+=("$!")

# If a service stops, reap it and shut down the others too.
status=0
wait -n "${children[@]}" || status=$?
if ((status == 0)); then status=1; fi
exit "$status"
