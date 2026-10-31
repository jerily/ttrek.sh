#!/usr/bin/env python3
"""Start a disposable copy of the app against an isolated local Valkey server."""
import base64
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
INSTALL = ROOT / "build/install"
VALKEY = os.environ.get("VALKEY_SERVER", "valkey-server")


def wait_for_port(port, process):
    for _ in range(100):
        if process.poll() is not None:
            raise RuntimeError(f"Process exited before port {port} opened")
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                return
        except OSError:
            time.sleep(0.1)
    raise RuntimeError(f"Timed out waiting for port {port}")


def stop(process):
    if process is not None and process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()


# app.tcl owns these listener ports. Refuse to disturb an existing server.
for port in (8080, 4433):
    with socket.socket() as probe:
        probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        probe.bind(("127.0.0.1", port))
with socket.socket() as probe:
    probe.bind(("127.0.0.1", 0))
    valkey_port = probe.getsockname()[1]

env = dict(os.environ, AWS_EC2_METADATA_DISABLED="true")
env["LD_LIBRARY_PATH"] = f"{INSTALL}/lib:{INSTALL}/lib64"
valkey_process = app_process = None
with tempfile.TemporaryDirectory(prefix="runtime-smoke-", dir=ROOT / "build") as temporary:
    app = Path(temporary)
    for name in ("app.tcl", "run.sh"):
        shutil.copy2(ROOT / name, app / name)
    for name in ("tcl", "www", "public", "registry"):
        shutil.copytree(ROOT / name, app / name)
    (app / "build").mkdir()
    (app / "build/install").symlink_to(INSTALL, target_is_directory=True)
    (app / "etc").mkdir()
    with (app / "certificate.log").open("w") as log:
        subprocess.run([
            str(INSTALL / "bin/openssl"), "req", "-x509", "-newkey", "rsa:2048",
            "-nodes", "-keyout", str(app / "key.pem"), "-out", str(app / "cert.pem"),
            "-days", "1", "-subj", "/CN=ttrek.sh",
        ], env=env, stdout=log, stderr=log, check=True)
    config = (ROOT / "tests/fixtures/local-config.ini.in").read_text().format(
        port=valkey_port,
        key=base64.b64encode((app / "key.pem").read_bytes()).decode(),
        certificate=base64.b64encode((app / "cert.pem").read_bytes()).decode(),
    )
    (app / "etc/config.ini").write_text(config)
    with (app / "valkey.log").open("w+") as valkey_log, (app / "app.log").open("w+") as app_log:
        try:
            valkey_process = subprocess.Popen([
                VALKEY, "--bind", "127.0.0.1", "--port", str(valkey_port),
                "--save", "", "--appendonly", "no", "--dir", str(app),
            ], stdout=valkey_log, stderr=subprocess.STDOUT)
            wait_for_port(valkey_port, valkey_process)
            app_process = subprocess.Popen([str(app / "run.sh")], cwd=app, env=env,
                                           stdout=app_log, stderr=subprocess.STDOUT,
                                           start_new_session=True)
            wait_for_port(8080, app_process)
            checks = {
                "/": "Install ttrek",
                "/packages": "jinja2-tcl",
                "/package/tcl": "9.1.0",
                "/package/tcl/9.1.0": "tcl@9.1.0",
                "/package/tjson/1.0.26": "tjson@1.0.26",
                "/request-monitor": "data-chart-config",
                "/js/chart.umd.js": "Chart.js",
                "/css/typebase.css": "Typebase",
                "/registry/tcl": "9.1.0",
            }
            for path, expected in checks.items():
                with urllib.request.urlopen("http://127.0.0.1:8080" + path, timeout=5) as response:
                    body = response.read().decode()
                    assert expected in body, f"Unexpected response for {path}"
                print(f"PASS GET {path}")
            app_log.seek(0)
            assert "Error while accessing telemetry db" not in app_log.read(), "Telemetry SQL failed"
            print("Runtime startup and HTTP smoke checks passed")
        except Exception:
            app_log.seek(0)
            print(app_log.read())
            raise
        finally:
            # run.sh execs the interpreter so termination reaches the server.
            stop(app_process)
            stop(valkey_process)
