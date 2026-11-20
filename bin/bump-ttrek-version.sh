#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
exec python3 - "$@" <<'PY'
import configparser
import json
import re
import sys
from pathlib import Path

number = r"(?:0|[1-9][0-9]*)"
version = rf"{number}\.{number}\.{number}"
if len(sys.argv) != 2 or not re.fullmatch(version, sys.argv[1]):
    sys.exit("Usage: bump-ttrek-version.sh X.Y.Z")
target = sys.argv[1]
changes = {}


def update(filename, *patterns):
    path = Path(filename)
    original = path.read_bytes().decode()
    text = original
    for pattern in patterns:
        # @ marks the release number within a unique bit of surrounding text.
        regex = pattern.replace("@", f"(?P<release>{version})")
        matches = list(re.finditer(regex, text, re.MULTILINE))
        if len(matches) != 1:
            sys.exit(f"{path}: expected one match for {pattern}, found {len(matches)}")
        start, end = matches[0].span("release")
        text = text[:start] + target + text[end:]
    if text != original:
        changes[path] = text


for filename in ("devops/config.prod.ini", "etc/config.ini",
                 "etc/config.local.ini.example", "etc/config.local.ini"):
    if filename.endswith(".local.ini") and not Path(filename).exists():
        continue
    section = r"^\[releases\][^\n]*\n(?:[^\[\n][^\n]*\n|\n)*?"
    equals = r"[ \t]*=[ \t]*"
    update(filename, section + "prefix" + equals + r"ttrek/@[ \t]*$",
           section + "version" + equals + r"@[ \t]*$")

update("devops/build-lambda.sh", r"^TTREK_BINARY_S3_URI=.*?/ttrek/@/linux-amd64-glibc/")
update("tcl/config.tcl", r"prefix ttrek/@ source_prefix", r"source_prefix ttrek/sources version @ ")
update("etc/tdevops.tcl", r'\$releases version\] eq "@"', r'\$releases prefix\] eq "ttrek/@"',
       r"ttrek-local/ttrek/@/\*/ttrek")
update("tests/all.tcl", r"public-releases\.s3\.eu-west-1\.amazonaws\.com/ttrek/@/")
update("tests/config.test", r"^test releases-config-9\b(?:(?!^test )[\s\S])*?^\} -result @$")
update("tests/lambda-config.test", r"jerily-ttrek-app\.s3\.eu-central-1\.amazonaws\.com/ttrek/@/",
       r"-result \{jerily-ttrek-app @ ")
update("tests/local-stack.tcl", r"\$seed ttrek-local ttrek @ ", r"dict create @ \[list M",
       r'\[releases\\\]\\nversion=@\\n', r"\$seedSource ttrek-local ttrek @\]",
       r"\$s3/ttrek-local/ttrek/@/", r'\$metadata version\] eq "@"')

fixture = Path("tests/fixtures/release-checksums.json")
prod = json.loads(fixture.read_bytes())["prod"]
defaults = configparser.ConfigParser(interpolation=None)
defaults.read("etc/config.ini")
current = defaults["releases"]["version"]
if current != target and target in prod:
    sys.exit(f"{fixture}: {target} already has a historical checksum")
update(fixture, r'^  "prod": \{[\s\S]*?^    "(?=' + re.escape(current) + r'")@":')

for path, text in changes.items():
    path.write_bytes(text.encode())
    print(path)
PY
