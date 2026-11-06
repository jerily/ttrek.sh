#!/usr/bin/env python3
"""Verify configured creation through the packaged local Lambda runtime."""
import argparse
import base64
import json
import os
from pathlib import Path
import re
import signal
import socket
import subprocess
import tempfile
import time
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--zip', type=Path, default=ROOT / 'dist/ttrek-sh.zip')
args = parser.parse_args()


def unused_port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


with tempfile.TemporaryDirectory(prefix='ttrek-editor-') as temporary:
    work = Path(temporary)
    database = work / 'docs.sqlite3'
    config = work / 'config.local.ini'
    env = dict(os.environ, TTREK_EDITOR_PASSWORD='test-editor', TTREK_LOCAL_CONFIG=str(config))
    authorization = 'Basic ' + base64.b64encode(b'admin:test-editor').decode()
    # Enabling creation, disabling it, then leaving edit mode must retain data
    # without accidentally exposing either writing endpoint.
    for mode in ('create', 'edit', 'readonly'):
        config.write_text('[content]\nallow_create = ' + ('false' if mode == 'edit' else 'true') + '\n')
        port = unused_port()
        command = [str(ROOT / 'bin/start-lambda.sh'), '--zip', str(args.zip.resolve()),
                   '--lambda-port', str(port), '--state-dir', str(work / 'state'), '--lambda-workers', '2']
        if mode != 'readonly':
            command += ['--edit', '--database', str(database)]
        with tempfile.TemporaryFile(mode='w+') as log:
            process = subprocess.Popen(command, env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
            try:
                deadline = time.monotonic() + 30
                while True:
                    if process.poll() is not None:
                        log.seek(0)
                        raise AssertionError(log.read())
                    try:
                        with urllib.request.urlopen(f'http://127.0.0.1:{port}/healthz', timeout=1) as health:
                            health.read()
                            break
                    except OSError:
                        if time.monotonic() > deadline:
                            log.seek(0)
                            raise AssertionError(log.read())
                        time.sleep(0.1)

                def invoke(path, method='GET', fields=None, auth=True, v2=False):
                    headers = {'Authorization': authorization} if auth else {}
                    event = dict(httpMethod=method, path=path, headers=headers)
                    if v2:
                        event = dict(version='2.0', rawPath=path, headers=headers,
                                     requestContext={'http': {'method': method, 'sourceIp': '127.0.0.1'}})
                    if fields is not None:
                        headers['Content-Type'] = 'application/x-www-form-urlencoded'
                        event.update(body=base64.b64encode(urllib.parse.urlencode(fields).encode()).decode(),
                                     isBase64Encoded=True)
                    request = urllib.request.Request(
                        f'http://127.0.0.1:{port}/2015-03-31/functions/ttrek-sh/invocations',
                        data=json.dumps(event).encode(), headers={'Content-Type': 'application/json', 'Connection': 'close'})
                    with urllib.request.urlopen(request, timeout=10) as response:
                        result = json.load(response)
                        assert not response.headers.get('x-amz-function-error'), result
                    result['body'] = base64.b64decode(result['body']).decode()
                    return result

                print('Checking local mode:', mode, flush=True)
                if mode == 'readonly':
                    assert invoke('/docs/_new')['statusCode'] == 404
                    assert invoke('/docs/_edit/getting-started')['statusCode'] == 404
                    continue
                assert invoke('/docs/_new', auth=False)['statusCode'] == 401
                if mode == 'edit':
                    assert invoke('/docs/_new')['statusCode'] == 404
                    assert invoke('/docs/_edit/getting-started')['statusCode'] == 200
                    assert 'Created through Lambda' in invoke('/docs/new-guide')['body']
                    continue
                tokens = set()
                for _ in range(8):
                    response = invoke('/docs/_new', v2=True)
                    assert response['statusCode'] == 200, response
                    tokens.add(re.search(r'name="csrf" value="([^"]+)"', response['body'])[1])
                    assert '/docs/_assets/markdown-editor.bundle.js' in response['body']
                assert len(tokens) == 1
                print('Shared CSRF and creation form passed', flush=True)
                fields = dict(title='New Guide', markdown='Created through Lambda — café.', csrf=tokens.pop())
                assert invoke('/docs/_new', 'POST', dict(fields, csrf='invalid'))['statusCode'] == 403
                saved = invoke('/docs/_new', 'POST', fields, v2=True)
                assert saved['statusCode'] == 303 and saved['headers']['location'] == '/docs/new-guide', saved
                assert invoke('/docs/_new', 'POST', fields)['statusCode'] == 409
                for _ in range(8):
                    assert 'Created through Lambda — café.' in invoke('/docs/new-guide')['body']
                print('Creation, conflict and persistence checks passed', flush=True)
            finally:
                if process.poll() is None:
                    # Let the worker finish its Runtime API response and return
                    # to /next before stopping the local emulator.
                    time.sleep(0.25)
                    process.send_signal(signal.SIGTERM)
                    try:
                        process.wait(timeout=20)
                    except subprocess.TimeoutExpired:
                        log.seek(0)
                        print(log.read())
                        os.killpg(process.pid, signal.SIGKILL)
                        process.wait()
                        raise
    assert not list((work / 'state').iterdir())
print('Local editor checks passed: configuration, authorization, CSRF, both event formats, persistence and read-only mode.')
