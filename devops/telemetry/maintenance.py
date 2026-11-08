"""Scheduled, restorable PostgreSQL backups and non-blocking morning vacuum."""
import datetime
import os
from pathlib import Path
import subprocess
import tempfile

import boto3


def handler(event, context):
    action = event.get("action")
    if action not in {"backup", "vacuum"}:
        raise ValueError("action must be backup or vacuum")
    secret = boto3.client("ssm").get_parameter(
        Name=os.environ["PASSWORD_PARAMETER"], WithDecryption=True
    )["Parameter"]
    if secret["Type"] != "SecureString":
        raise ValueError("The database password parameter must be a SecureString")
    environment = dict(os.environ, PGPASSWORD=secret["Value"], PGSSLMODE="verify-full",
                       PGSSLROOTCERT="/var/task/rds-global-bundle.pem", PGCONNECT_TIMEOUT="10")
    timeout = max(1, int(context.get_remaining_time_in_millis() / 1000) - 60)
    if action == "vacuum":
        # VACUUM FULL is intentionally avoided: it would lock the tables.
        subprocess.run(["/var/task/bin/psql", "--no-password", "--no-psqlrc",
                        "--set", "ON_ERROR_STOP=1", "--command", "VACUUM (ANALYZE);"],
                       env=environment, check=True, timeout=timeout)
        return {"action": action, "status": "completed"}
    with tempfile.TemporaryDirectory(prefix="telemetry-", dir="/tmp") as temporary:
        dump = Path(temporary) / "telemetry.dump"
        subprocess.run(["/var/task/bin/pg_dump", "--no-password", "--format=custom",
                        "--no-owner", "--no-acl", "--file", str(dump)],
                       env=environment, check=True, timeout=timeout)
        timestamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y/%m/%d/%Y%m%dT%H%M%SZ")
        key = f"telemetry/backups/{timestamp}-{context.aws_request_id}.dump"
        boto3.client("s3").upload_file(str(dump), os.environ["BACKUP_BUCKET"], key,
                                     ExtraArgs={"ServerSideEncryption": "AES256"})
    print(f"Backup uploaded: s3://{os.environ['BACKUP_BUCKET']}/{key}")
    return {"action": action, "key": key}
