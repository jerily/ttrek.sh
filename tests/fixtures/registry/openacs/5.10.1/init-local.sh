#!/bin/sh
set -eu
cd "$PROJECT_HOME"
OACS_PREFIX="${OACS_PREFIX:-$PROJECT_INSTALL_DIR}"
OACS_RUNTIME="${OACS_RUNTIME:-$PROJECT_HOME/openacs-local}"

umask 077
mkdir -m 700 "$OACS_RUNTIME"
mkdir "$OACS_RUNTIME/socket"
"$OACS_PREFIX/postgresql/bin/initdb" -D "$OACS_RUNTIME/db" \
  --encoding=UTF8 --no-locale --auth-local=peer --auth-host=reject
"$OACS_PREFIX/bin/openacs-create-instance" "$OACS_RUNTIME/site"

# pg_ctl passes its options through a shell; quote the socket path.
socket=$(printf '%s' "$OACS_RUNTIME/socket" | sed "s/'/'\\\\''/g")
"$OACS_PREFIX/postgresql/bin/pg_ctl" -D "$OACS_RUNTIME/db" \
  -l "$OACS_RUNTIME/postgres.log" \
  -o "-k '$socket' -p 55432 -c listen_addresses=''" -w start
trap '"$OACS_PREFIX/postgresql/bin/pg_ctl" -D "$OACS_RUNTIME/db" -m fast -w stop' 0
trap 'exit 130' INT
trap 'exit 143' TERM

"$OACS_PREFIX/postgresql/bin/createdb" \
  -h "$OACS_RUNTIME/socket" -p 55432 -U "$(id -un)" --encoding=UTF8 openacs
"$OACS_PREFIX/postgresql/bin/psql" -X \
  -h "$OACS_RUNTIME/socket" -p 55432 -U "$(id -un)" -d openacs \
  -v ON_ERROR_STOP=1 -c 'CREATE EXTENSION hstore'
printf '%s\n' 'Initialized local OpenACS instance. Run: ttrek run -package openacs -script start-local'
