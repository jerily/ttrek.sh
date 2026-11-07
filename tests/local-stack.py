#!/usr/bin/env python3
"""Exercise the packaged site through all three installed mock apps."""
import base64
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[1]


def reserve_ports():
    probes = [socket.socket() for _ in range(3)]
    try:
        for probe in probes:
            probe.bind(("127.0.0.1", 0))
        return [probe.getsockname()[1] for probe in probes]
    finally:
        for probe in probes:
            probe.close()


port, lambda_port, s3_port = reserve_ports()
base = f"http://127.0.0.1:{port}"
s3 = f"http://127.0.0.1:{s3_port}"


def request(path, status=200, method="GET", data=None, content_type="application/octet-stream"):
    url = path if path.startswith("http:") else base + path
    headers = {"Content-Type": content_type} if data is not None else {}
    try:
        response = urllib.request.urlopen(
            urllib.request.Request(url, data=data, headers=headers, method=method), timeout=30)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        body = response.read()
        assert response.status == status, (url, response.status, body[:500])
        return body, response.headers


archive = ROOT / "dist/ttrek-sh.zip"
before = hashlib.sha256(archive.read_bytes()).hexdigest()
with tempfile.TemporaryDirectory(prefix="local stack ", dir=ROOT / "build") as temporary:
    state = Path(temporary) / "state"
    seed = Path(temporary) / "s3"
    shutil.copytree(ROOT / "dist/s3", seed)
    extra_target = "macos-universal2"
    extra_binary = b"uploaded release bytes\x00\xff"
    extra_checksum = hashlib.sha256(extra_binary).hexdigest()
    extra_seed = seed / "ttrek-local/ttrek/1.0.0" / extra_target / "ttrek"
    extra_seed.parent.mkdir(parents=True, exist_ok=True)
    extra_seed.write_bytes(b"old seed bytes")
    manifest = Path(temporary) / "releases.json"
    manifest.write_text(json.dumps({"local": {"1.0.0": {extra_target: extra_checksum}},
                                    "prod": {"1.0.0": {extra_target: "a" * 64}}}))
    config = Path(temporary) / "config.ini"
    config.write_text(f"[releases]\nversion=1.0.0\nchecksums_file={manifest}\n")
    with (Path(temporary) / "services.log").open("w+") as log:
        process = subprocess.Popen([
            str(ROOT / "bin/start-local.sh"), "--zip", str(archive), "--port", str(port),
            "--lambda-port", str(lambda_port), "--s3-port", str(s3_port),
            "--state-dir", str(state), "--s3-dir", str(seed), "--lambda-workers", "2",
        ], cwd=ROOT, env={**os.environ, "TTREK_LOCAL_CONFIG": str(config)},
            stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            deadline = time.monotonic() + 180
            while True:
                if process.poll() is not None:
                    raise AssertionError(f"local stack exited: {process.returncode}")
                try:
                    request(s3 + "/")
                    homepage, _ = request("/")
                    break
                except (OSError, AssertionError):
                    if time.monotonic() >= deadline:
                        raise
                    time.sleep(0.2)
            assert b'href="/docs"' in homepage
            assert b'href="/blog"' in homepage
            assert b"Sign Up" not in homepage
            for path, expected in {
                "/docs": b"Getting started",
                "/blog": b"No published content yet.",
                "/docs/getting-started": b"ttrek init -y",
                "/docs/registries": b"private-ttrek-registry",
                "/docs/_assets/style.css": b".cards",
                "/packages": b"tjson",
                "/package/tcl": b"9.1.0",
                "/package/web-static-blog": b"0.1.0",
                "/registry/web-static-wiki": b"0.1.0",
                "/registry/tcl": b"9.1.0",
                "/registry/search?q=web": b"twebserver",
                "/request-monitor": b"data-chart-config",
                "/init": b"TTREK_UPDATE_ROOT",
            }.items():
                body, _ = request(path)
                assert expected in body, (path, body[:500])
                print(f"PASS GET {path}")
            docs, headers = request("/docs/getting-started")
            assert b"<title>Getting started" in docs
            assert b"new ClipboardJS" not in docs
            assert "script-src 'self'" in headers["content-security-policy"]
            assert request("/docs", method="HEAD")[0] == b""
            request("/docs/missing", 404)
            request("/docs/_edit/getting-started", 404)
            request("/docs/_new", 404)
            request("/blog/_new", 404)
            request("/blog/_edit/post", 404)
            request("/docs", 405, method="POST", data=b"")
            request("/registry/search?q=one&q=two", 400)
            request("/telemetry/collect/demo/1.0.0", 400, method="POST", data=b"invalid")
            print("PASS static content, HEAD, read-only routes and request validation")

            def invoke(event, status=200):
                body, headers = request(
                    f"http://127.0.0.1:{lambda_port}/2015-03-31/functions/ttrek-sh/invocations",
                    method="POST", data=json.dumps(event).encode(), content_type="application/json")
                assert "x-amz-function-error" not in headers, body
                response = json.loads(body)
                assert response["statusCode"] == status, response
                return base64.b64decode(response["body"])

            event = {"httpMethod": "GET", "path": "/registry/search", "headers": None,
                     "queryStringParameters": {"q": "web"}, "multiValueQueryStringParameters": None}
            assert json.loads(invoke(event))[0]["name"] == "twebserver"
            event["multiValueQueryStringParameters"] = {"q": ["web", "server"]}
            invoke(event, 400)
            telemetry = {"action": "install", "outcome": "success", "is_toplevel": True,
                         "os": "Linux", "arch": "x86_64"}
            assert invoke({"httpMethod": "POST", "path": "/telemetry/collect/demo/1.0.0",
                           "headers": {"Content-Type": "application/json"},
                           "body": base64.b64encode(json.dumps(telemetry).encode()).decode(),
                           "isBase64Encoded": True}) == b"ok"
            print("PASS payload 1.0 queries, duplicate validation and base64 request body")

            # Changing a mock S3 object must change the asset returned through
            # the Lambda adapter; this detects accidentally serving checkout files.
            original = (ROOT / "public/css/docs.css").read_bytes()
            assert request("/css/docs.css")[0] == original
            changed = original + b"\n/* served from mock S3 */\n"
            request(s3 + "/ttrek-assets/css/docs.css", method="PUT", data=changed, content_type="text/css")
            assert request("/css/docs.css")[0] == changed
            binary = bytes(range(256)) * 5
            request(s3 + "/ttrek-local/binary.bin", method="PUT", data=binary)
            assert request(s3 + "/ttrek-local/binary.bin")[0] == binary
            print("PASS S3-backed website assets and binary object storage")

            release = next((ROOT / "dist/s3/ttrek-local/ttrek/1.0.0").glob("*/ttrek"))
            target = release.parent.name
            download, _ = request(f"/dist/{target}/ttrek")
            assert hashlib.sha256(download).digest() == hashlib.sha256(release.read_bytes()).digest()
            metadata = json.loads(request(f"/releases/latest/{target}")[0])
            assert metadata["sha256"] == hashlib.sha256(download).hexdigest()
            assert metadata["url"].startswith(s3 + "/ttrek-local/")
            print("PASS signed release redirect, exact executable bytes and checksum metadata")

            request(f"{s3}/ttrek-local/ttrek/1.0.0/{extra_target}/ttrek", method="PUT", data=extra_binary)
            download, _ = request(f"/dist/{extra_target}/ttrek")
            metadata = json.loads(request(f"/releases/latest/{extra_target}")[0])
            assert download == extra_binary
            assert metadata["sha256"] == extra_checksum
            assert metadata["version"] == "1.0.0"
            print("PASS configured local checksum manifest takes precedence over seed and production hashes")
        except Exception:
            log.flush()
            log.seek(0)
            print(log.read())
            raise
        finally:
            process.send_signal(signal.SIGTERM)
            try:
                process.wait(timeout=30)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
                raise AssertionError("local supervisor did not stop its services")
        assert not list(state.iterdir()), "temporary service directories were not cleaned"
        assert hashlib.sha256(archive.read_bytes()).hexdigest() == before
        for selected in (port, lambda_port, s3_port):
            with socket.socket() as probe:
                assert probe.connect_ex(("127.0.0.1", selected)) != 0, "service left running"
        print("PASS clean shutdown and unchanged archive")
