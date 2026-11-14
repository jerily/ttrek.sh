#!/bin/sh
set -eu
cd "$PROJECT_HOME"
OACS_PREFIX="${OACS_PREFIX:-$PROJECT_INSTALL_DIR}"
OACS_RUNTIME="${OACS_RUNTIME:-$PROJECT_HOME/openacs-local}"

if [ ! -f "$OACS_RUNTIME/site/etc/ttrek-config.tcl" ]; then
  echo 'Initialize the local instance first: ttrek run -package openacs -script init-local' >&2
  exit 1
fi

# pg_ctl passes its options through a shell; quote the socket path.
socket=$(printf '%s' "$OACS_RUNTIME/socket" | sed "s/'/'\\\\''/g")
"$OACS_PREFIX/postgresql/bin/pg_ctl" -D "$OACS_RUNTIME/db" \
  -l "$OACS_RUNTIME/postgres.log" \
  -o "-k '$socket' -p 55432 -c listen_addresses=''" -w start
trap '"$OACS_PREFIX/postgresql/bin/pg_ctl" -D "$OACS_RUNTIME/db" -m fast -w stop' 0
trap 'exit 130' INT
trap 'exit 143' TERM

PGHOST="$OACS_RUNTIME/socket" \
oacs_db_host=localhost \
oacs_db_port=55432 \
oacs_db_name=openacs \
oacs_db_user="$(id -un)" \
oacs_httpport="${oacs_httpport:-8000}" \
  "$OACS_PREFIX/bin/nsd" -f -t "$OACS_RUNTIME/site/etc/ttrek-config.tcl"
