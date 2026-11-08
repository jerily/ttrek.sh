#!/usr/bin/env python3
"""Keep the decrypted SSM password in memory and pipes, never argv/files/logs."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import zipfile


def main():
    template, archive, *aws_options = sys.argv[1:]
    archive = Path(archive).resolve()
    with zipfile.ZipFile(archive) as source:
        for name in ("maintenance.py", "bin/pg_dump", "bin/psql", "rds-global-bundle.pem"):
            source.getinfo(name)
    result = subprocess.run([
        "aws", "ssm", "get-parameter", "--name", "/ttrek_sh/prod/postgres/password",
        "--with-decryption", "--output", "json", *aws_options,
    ], stdout=subprocess.PIPE, text=True, check=True)
    parameter = json.loads(result.stdout)["Parameter"]
    password = parameter["Value"]
    if (parameter["Type"] != "SecureString" or not 8 <= len(password) <= 128
            or any(not 33 <= ord(c) <= 126 or c in '/@"' for c in password)):
        sys.exit('SSM postgres/password must be a SecureString: 8-128 printable ASCII characters, excluding space, /, @ and double quote')
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    key = f"lambda/telemetry-maintenance/{digest}.zip"
    subprocess.run(["aws", "s3", "cp", str(archive), f"s3://jerily-ttrek-app/{key}",
                    "--only-show-errors", *aws_options], check=True, stdout=subprocess.PIPE)
    values = {
        "DatabasePassword": password,
        "MaintenanceCodeKey": key,
        "ScheduleTimezone": os.environ.get("TTREK_SCHEDULE_TIMEZONE", "America/New_York"),
        "BackupSchedule": os.environ.get("TTREK_BACKUP_SCHEDULE", "cron(0 5 * * ? *)"),
        "VacuumSchedule": os.environ.get("TTREK_VACUUM_SCHEDULE", "cron(0 6 * * ? *)"),
    }
    parameters = json.dumps([{"ParameterKey": k, "ParameterValue": v} for k, v in values.items()])
    with subprocess.Popen([
        "aws", "cloudformation", "deploy", "--template-file", template,
        "--stack-name", "Infra-DevOps-TTREK-Postgres", "--capabilities", "CAPABILITY_NAMED_IAM",
        "--parameter-overrides", "file:///dev/stdin", "--no-fail-on-empty-changeset", *aws_options,
    ], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True) as deployment:
        deployment.stdin.write(parameters)
        deployment.stdin.close()
        for line in deployment.stdout:
            print(line, end="", flush=True)
        return deployment.wait()


if __name__ == "__main__":
    try:
        sys.exit(main())
    except subprocess.CalledProcessError as error:
        sys.exit(error.returncode)
