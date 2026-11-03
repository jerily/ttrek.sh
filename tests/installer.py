"""Run the installer with platform/download fixtures and a disposable install home."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]

with tempfile.TemporaryDirectory(prefix="ttrek-installer-") as temporary:
    root = Path(temporary)
    tools = root / "bin"
    tools.mkdir()
    # Restrict PATH so curl/wget selection is deterministic on any test host.
    for command in ("uname", "mktemp", "chmod", "mkdir", "rm", "rmdir", "cp", "grep", "head", "tail", "cut"):
        path = shutil.which(command)
        assert path, command
        (tools / command).symlink_to(path)

    def mock(name, body):
        path = tools / name
        if path.is_symlink():
            path.unlink()
        path.write_text(f"#!{sys.executable}\n" + body)
        path.chmod(0o755)

    mock("uname", "import os,sys\nprint({'-s':os.environ['TEST_OS'], '-m':os.environ['TEST_CPU'], '-o':'GNU/Linux'}[sys.argv[1]])\n")
    mock("ldd", "import os\nprint(os.environ['TEST_LIBC'])\n")
    mock("sysctl", "import os,sys\nprint(sys.argv[1] + ': ' + os.environ['TEST_ARM64'])\n")
    mock("sw_vers", "print('14.0')\n")
    downloader = '''import json,os,sys
from pathlib import Path
args = sys.argv[1:]
if '--help' in args:
    print('--proto --tlsv1.2 --ciphers --retry --continue-at --https-only --secure-protocol')
elif '-V' in args:
    print('curl 8.7.1 OpenSSL/3.0' if sys.argv[0].endswith('curl') else 'GNU Wget 1.21')
else:
    Path(os.environ['TEST_DOWNLOAD']).write_text(json.dumps(args))
    flag = '--output' if '--output' in args else '-O'
    Path(args[args.index(flag) + 1]).write_bytes(b'ttrek test distribution')
'''
    cases = [
        ("Linux", "x86_64", "glibc", "0", "x86_64-unknown-linux-gnu"),
        ("Linux", "aarch64", "glibc", "0", "aarch64-unknown-linux-gnu"),
        ("Linux", "x86_64", "musl", "0", "x86_64-unknown-linux-musl"),
        ("Linux", "aarch64", "musl", "0", "aarch64-unknown-linux-musl"),
        ("Darwin", "arm64", "", "1", "aarch64-apple-darwin"),
        ("Darwin", "x86_64", "", "0", "x86_64-apple-darwin"),
        ("Darwin", "x86_64", "", "1", "aarch64-apple-darwin"),  # Rosetta chooses native ARM64.
    ]
    for client in ("curl", "wget"):
        other = tools / ("wget" if client == "curl" else "curl")
        other.unlink(missing_ok=True)
        mock(client, downloader)
        for number, (system, cpu, libc, arm64, triple) in enumerate(cases):
            if system == "Linux" and not Path('/proc/self/exe').is_symlink():
                continue
            home = root / f"{client}-{number}"
            home.mkdir()
            env = dict(os.environ, PATH=str(tools), HOME=str(home), TEST_OS=system,
                       TEST_CPU=cpu, TEST_LIBC=libc, TEST_ARM64=arm64,
                       TEST_DOWNLOAD=str(home / "download.json"))
            env.pop("TTREK_UPDATE_ROOT", None)
            env.pop("TTREK_HOME", None)
            result = subprocess.run(["/bin/sh", str(ROOT / "public/ttrek-init"), "-y"], env=env,
                                    capture_output=True, text=True, timeout=10)
            assert result.returncode == 0, (system, cpu, result.stdout, result.stderr)
            args = json.loads((home / "download.json").read_text())
            assert f"https://ttrek.sh/dist/{triple}/ttrek" in args, args
            assert '-k' not in args and '--no-check-certificate' not in args
            if client == "curl":
                assert '--location' in args
            assert (home / ".ttrek/bin/ttrek").read_bytes() == b'ttrek test distribution'
            assert (home / ".ttrek/bin/ttrek").stat().st_mode & 0o100
            # Overrides retain the same endpoint and normalize a trailing slash.
            env['TTREK_UPDATE_ROOT'] = 'https://localhost:4433/'
            subprocess.run(["/bin/sh", str(ROOT / "public/ttrek-init"), "-y"], env=env,
                           capture_output=True, check=True, timeout=10)
            assert f"https://localhost:4433/dist/{triple}/ttrek" in json.loads((home / "download.json").read_text())
print('Installer endpoints, Linux libc/architecture, native/Intel/Rosetta macOS and curl/wget checks passed')
