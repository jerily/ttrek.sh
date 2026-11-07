#!/usr/bin/env python3
"""Start a disposable copy of the app against an isolated local Valkey server."""
import base64
import json
import os
from pathlib import Path
import shutil
import socket
import ssl
import subprocess
import tempfile
import time
import urllib.parse
import urllib.request
import urllib.error

ROOT = Path(__file__).resolve().parents[1]
INSTALL = Path(os.environ.get("TTREK_SITE_PREFIX", ROOT / "ttrek-venv/local"))
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


# Use separate ports for the disposable application and Valkey instance.
ports = []
for _ in range(3):
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        ports.append(probe.getsockname()[1])
http_port, https_port, valkey_port = ports

mode = os.environ.get("ENV", "LOCAL")
assert mode in ("LOCAL", "PROD")
env = dict(os.environ, AWS_EC2_METADATA_DISABLED="true", ENV=mode)
env["TTREK_SITE_PREFIX"] = str(INSTALL)
env["LD_LIBRARY_PATH"] = f"{INSTALL}/lib:{INSTALL}/lib64"
valkey_process = app_process = None
with tempfile.TemporaryDirectory(prefix="runtime-smoke-", dir=ROOT / "build") as temporary:
    app = Path(temporary)
    for name in ("app.tcl", "run.sh"):
        shutil.copy2(ROOT / name, app / name)
    copied_app = app / "app.tcl"
    copied_app.write_text(copied_app.read_text().replace("$server_handle 4433", f"$server_handle {https_port}")
                          .replace("$server_handle 8080", f"$server_handle {http_port}"))
    for name in ("tcl", "www", "public", "schemas", "bin", "content"):
        shutil.copytree(ROOT / name, app / name)
    registry_dir = "package registry"
    shutil.copytree(ROOT / "registry", app / registry_dir, ignore=shutil.ignore_patterns(".git"))
    # Stable fuzzy-search candidate independent of the pinned registry contents.
    search_recipe = app / registry_dir / "tclx" / "1.0.0"
    search_recipe.mkdir(parents=True, exist_ok=True)
    (search_recipe / "ttrek.json").write_text('{}')
    subprocess.run([str(INSTALL / "bin/tclsh9.1"), str(app / "bin/build-search.tcl"),
                    str(app / registry_dir)], env=env, check=True)
    (app / "build").mkdir()
    (app / "build/install").symlink_to(INSTALL, target_is_directory=True)
    (app / "etc").mkdir(exist_ok=True)
    with (app / "certificate.log").open("w") as log:
        subprocess.run([
            str(INSTALL / "bin/openssl"), "req", "-x509", "-newkey", "rsa:2048",
            "-config", "/dev/null",
            "-nodes", "-keyout", str(app / "key.pem"), "-out", str(app / "cert.pem"),
            "-days", "1", "-subj", "/CN=localhost",
            "-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1",
        ], env=env, stdout=log, stderr=log, check=True)
    config = (ROOT / "tests/fixtures/local-config.ini.in").read_text().format(
        registry_dir=registry_dir,
        port=valkey_port,
        ca_file=app / "cert.pem",
        key=base64.b64encode((app / "key.pem").read_bytes()).decode(),
        certificate=base64.b64encode((app / "cert.pem").read_bytes()).decode(),
    )
    config_name = "config.local.ini" if mode == "LOCAL" else "config.ini"
    (app / "etc" / config_name).write_text(config)
    (app / "users.acl").write_text("user default off\nuser appuser on >tls-smoke-password ~* +@all\n")
    with (app / "valkey.log").open("w+") as valkey_log, (app / "app.log").open("w+") as app_log:
        try:
            valkey_process = subprocess.Popen([
                VALKEY, "--bind", "127.0.0.1", "--port", "0", "--tls-port", str(valkey_port),
                "--tls-cert-file", str(app / "cert.pem"), "--tls-key-file", str(app / "key.pem"),
                "--tls-ca-cert-file", str(app / "cert.pem"), "--tls-auth-clients", "no",
                "--aclfile", str(app / "users.acl"),
                "--save", "", "--appendonly", "no", "--dir", str(app),
            ], stdout=valkey_log, stderr=subprocess.STDOUT)
            wait_for_port(valkey_port, valkey_process)
            app_process = subprocess.Popen([str(app / "run.sh")], cwd=app, env=env,
                                           stdout=app_log, stderr=subprocess.STDOUT,
                                           start_new_session=True)
            wait_for_port(http_port, app_process)
            checks = {
                "/": "http://localhost:8080/init | ENV=LOCAL sh" if mode == "LOCAL" else "https://ttrek.sh/init",
                "/packages": "jinja2-tcl",
                "/docs": "Getting started",
                "/blog": "No published content yet.",
                "/docs/getting-started": "ttrek init -y",
                "/package/tcl": "9.1.0",
                "/package/tcl/9.1.0": "tcl@9.1.0",
                "/package/tjson/1.0.26": "tjson@1.0.26",
                "/request-monitor": "data-chart-config",
                "/js/chart.umd.js": "Chart.js",
                "/css/typebase.css": "Typebase",
                "/registry/tcl": "9.1.0",
            }
            for path, expected in checks.items():
                with urllib.request.urlopen(f"http://127.0.0.1:{http_port}" + path, timeout=5) as response:
                    body = response.read().decode()
                    assert expected in body, f"Unexpected response for {path}"
                print(f"PASS GET {path}")
            for path, status in (("/dist/linux-amd64-glibc/ttrek", 503),
                                 ("/releases/latest/linux-amd64-glibc", 503),
                                 ("/dist/unknown/ttrek", 404)):
                try:
                    urllib.request.urlopen(f"http://127.0.0.1:{http_port}" + path, timeout=5)
                    raise AssertionError(f"Expected {status} for {path}")
                except urllib.error.HTTPError as response:
                    assert response.code == status
                    if status == 503:
                        assert response.headers["Cache-Control"] == "no-store"
                print(f"PASS GET {path}: {status}")
            cli = Path(os.environ.get("TTREK_SEARCH_BINARY", ROOT.parent / "ttrek/build/ttrek"))
            tiers = {kind: i for i, kind in enumerate(("exact", "prefix", "substring", "description", "fuzzy", "description-fuzzy"))}
            for query in ("tcl", "tcll", "web", "compression", "encrytion", "web server", "c++", " WEB ", "no-such-recipe-xyz"):
                url = f"http://127.0.0.1:{http_port}/registry/search?" + urllib.parse.urlencode({"q": query})
                with urllib.request.urlopen(url, timeout=5) as response:
                    matches = json.load(response)
                    assert response.headers.get_content_type() == "application/json"
                    def rank(match):
                        unmatched = len(match["name"]) - len(query) if match["match"] in ("prefix", "substring") else 0
                        return (tiers[match["match"]], match.get("distance", 0), -match.get("coverage", 0), unmatched, match["name"])
                    assert matches == sorted(matches, key=rank)
                    assert all("description" in match for match in matches)
                    assert len({match["name"] for match in matches}) == len(matches)
                    if query == "web":
                        assert any(match["name"] == "twebserver" and "web server" in match["description"] for match in matches)
                        assert "b" not in {match["name"] for match in matches}
                    elif query == "tcl":
                        assert matches[0]["name"] == "tcl" and matches[0]["match"] == "exact"
                    elif query == "encrytion":
                        assert any(match["name"] == "tink-tcl" and match["distance"] == 1 for match in matches)
                    elif query == "no-such-recipe-xyz":
                        assert matches == []
                    if cli.is_file():
                        result = subprocess.run([str(cli), "search", "-registry", str(app / registry_dir), query],
                                                env=env, capture_output=True, text=True, timeout=5, check=True)
                        rows = [line.partition("\t")[::2] for line in result.stdout.splitlines()]
                        assert rows == [(match["name"], match["description"]) for match in matches], (query, rows, matches)
                print(f"PASS recipe search{' and CLI parity' if cli.is_file() else ''}: {query}")
            for suffix in ("", "?q=", "?q=..%2Fetc", "?q=web&q=server", "?q=%7Bweb%20server%7D", "?q=" + "a" * 256):
                try:
                    urllib.request.urlopen(f"http://127.0.0.1:{http_port}/registry/search{suffix}", timeout=5)
                    raise AssertionError("Expected invalid search to return 400")
                except urllib.error.HTTPError as response:
                    assert response.code == 400
            telemetry = {"action": "install", "outcome": "success", "is_toplevel": True,
                         "os": "Linux", "arch": "x86_64"}
            for payload, content_type, expected in (
                (json.dumps(telemetry).encode(), "application/json", 200),
                (json.dumps(dict(telemetry, is_toplevel="true")).encode(), "application/json", 400),
                (b"{} trailing", "application/json", 400),
                (json.dumps(telemetry).encode(), "text/plain", 400),
            ):
                request = urllib.request.Request(
                    f"http://127.0.0.1:{http_port}/telemetry/collect/tcl/9.1.0",
                    data=payload, headers={"Content-Type": content_type}, method="POST")
                try:
                    response = urllib.request.urlopen(request, timeout=5)
                except urllib.error.HTTPError as error:
                    response = error
                with response:
                    assert response.status == expected, (response.status, response.read())
            print("PASS telemetry request schemas and HTTP 400 errors")
            if mode == "LOCAL":
                context = ssl.create_default_context(cafile=str(app / "cert.pem"))
                with urllib.request.urlopen(f"https://localhost:{https_port}/", context=context, timeout=5) as response:
                    assert "Install ttrek" in response.read().decode()
                print("PASS HTTPS localhost with certificate verification")
            for action in ("verify", "disconnect"):
                subprocess.run([str(INSTALL / "bin/tclsh9.1"), str(ROOT / "tests/cache-smoke.tcl"),
                                str(app), action], env=env, check=True, timeout=10)
            # All workers must reestablish authenticated TLS after their sockets close.
            with urllib.request.urlopen(f"http://127.0.0.1:{http_port}/request-monitor", timeout=10) as response:
                assert "data-chart-config" in response.read().decode()
            subprocess.run([str(INSTALL / "bin/tclsh9.1"), str(ROOT / "tests/cache-smoke.tcl"),
                            str(app), "verify"], env=env, check=True, timeout=10)
            app_log.seek(0)
            assert "Error while accessing telemetry db" not in app_log.read(), "Telemetry SQL failed"
            print(f"{mode} startup, HTTP, TLS stores and reconnect checks passed")
        except Exception:
            app_log.seek(0)
            print(app_log.read())
            raise
        finally:
            # run.sh execs the interpreter so termination reaches the server.
            stop(app_process)
            stop(valkey_process)
