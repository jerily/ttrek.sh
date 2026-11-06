# Shared interpreter and native-library setup for bin/ launchers.
# The caller supplies SITE_ROOT.
SITE_PREFIX=${TTREK_SITE_PREFIX:-${PROJECT_INSTALL_DIR:-"$SITE_ROOT/ttrek-venv/local"}}
SITE_TCLSH=${TCLSH:-}
if [ -z "$SITE_TCLSH" ]; then
    for interpreter in tclsh9.1 tclsh9.0 tclsh8.7 tclsh8.6 tclsh; do
        if [ -x "$SITE_PREFIX/bin/$interpreter" ]; then
            SITE_TCLSH="$SITE_PREFIX/bin/$interpreter"
            break
        fi
    done
fi
if [ -z "$SITE_TCLSH" ]; then
    for interpreter in tclsh9.1 tclsh9.0 tclsh8.7 tclsh8.6 tclsh; do
        if command -v "$interpreter" >/dev/null 2>&1; then
            SITE_TCLSH=$(command -v "$interpreter")
            break
        fi
    done
fi
if [ -z "$SITE_TCLSH" ]; then
    printf '%s\n' 'No Tcl interpreter found. Install dependencies or set TCLSH.' >&2
    exit 1
fi
TTREK_SITE_PREFIX=$SITE_PREFIX
PATH="$SITE_PREFIX/bin:$PATH"
LD_LIBRARY_PATH="$SITE_PREFIX/lib:$SITE_PREFIX/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export TTREK_SITE_PREFIX LD_LIBRARY_PATH PATH
