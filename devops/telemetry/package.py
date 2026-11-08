#!/usr/bin/env python3
"""Run inside AL2023: package PostgreSQL clients and dependencies for Lambda."""
from pathlib import Path
import re
import subprocess
import zipfile

root = Path("/source")
output = Path("/output/telemetry-maintenance.zip")
clients = [Path("/usr/bin/pg_dump"), Path("/usr/bin/psql")]
libraries = set()
for client in clients:
    listing = subprocess.check_output(["ldd", str(client)], text=True)
    for path in re.findall(r"(?:=>\s+|^\s*)(/\S+)", listing, re.MULTILINE):
        library = Path(path)
        # Use the Lambda runtime's glibc and dynamic loader.
        if library.name.startswith(("ld-linux", "libc.so", "libm.so", "libpthread.so", "libdl.so", "librt.so")):
            continue
        libraries.add(library)
with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED) as archive:
    archive.write(root / "devops/telemetry/maintenance.py", "maintenance.py")
    archive.write(root / "etc/rds-global-bundle.pem", "rds-global-bundle.pem")
    for client in clients:
        archive.write(client, f"bin/{client.name}")
    for library in sorted(libraries):
        archive.write(library, f"lib/{library.name}")
print(output)
