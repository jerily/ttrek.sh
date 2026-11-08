#!/usr/bin/env python3
"""Check required runtime files and set executable ZIP attributes for Lambda."""
import os
from pathlib import Path
import stat
import sys
import tempfile
import zipfile


def finalize(path):
    descriptor, temporary = tempfile.mkstemp(dir=path.parent, suffix=".zip")
    os.close(descriptor)
    try:
        with zipfile.ZipFile(path) as source, zipfile.ZipFile(temporary, "w") as target:
            for required in ("bootstrap", "local/bin/tclsh", "etc/config.ini", "etc/releases.json"):
                source.getinfo(required)
            if "etc/config.local.ini" in source.namelist():
                raise ValueError("Local configuration must not be in the deployment archive")
            for entry in source.infolist():
                if entry.filename in ("bootstrap", "local/bin/tclsh"):
                    entry.create_system = 3
                    entry.external_attr = (stat.S_IFREG | 0o755) << 16
                target.writestr(entry, source.read(entry))
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("Usage: finalize-lambda.py ARCHIVE")
    finalize(Path(sys.argv[1]).resolve())
