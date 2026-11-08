#!/usr/bin/env python3
"""Keep the decrypted SSM password in memory and pipes, never argv/files/logs."""
import json
import os
import subprocess
import sys


def main():
    template, *aws_options = sys.argv[1:]
    result = subprocess.run([
        "aws", "ssm", "get-parameter", "--name", "/ttrek_sh/prod/postgres/password",
        "--with-decryption", "--output", "json", *aws_options,
    ], stdout=subprocess.PIPE, text=True, check=True)
    parameter = json.loads(result.stdout)["Parameter"]
    password = parameter["Value"]
    if (parameter["Type"] != "SecureString" or not 8 <= len(password) <= 128
            or any(not 33 <= ord(c) <= 126 or c in '/@"' for c in password)):
        sys.exit('SSM postgres/password must be a SecureString: 8-128 printable ASCII characters, excluding space, /, @ and double quote')
    values = {
        "DatabasePassword": password,
        "WebsiteFunctionName": os.environ.get("LAMBDA_FUNCTION_NAME", "prod-Api-TtrekWebsite-Function"),
        "ScheduleTimezone": os.environ.get("TTREK_SCHEDULE_TIMEZONE", "America/New_York"),
        "MaintenanceSchedule": os.environ.get("TTREK_MAINTENANCE_SCHEDULE", "cron(0 5 * * ? *)"),
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
