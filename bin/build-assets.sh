#!/bin/sh
set -eu
SITE_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$SITE_ROOT"
npm ci --ignore-scripts
exec npm run build -- "$@"
