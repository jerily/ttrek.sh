#!/usr/bin/env python3
"""Backup behavior tests with isolated AWS clients and PostgreSQL processes."""
import importlib.util
import os
from pathlib import Path
import subprocess
import unittest
from unittest.mock import Mock, patch

spec = importlib.util.spec_from_file_location("maintenance", Path(__file__).parents[1] / "devops/telemetry/maintenance.py")
maintenance = importlib.util.module_from_spec(spec)
spec.loader.exec_module(maintenance)


class MaintenanceTests(unittest.TestCase):
    def setUp(self):
        self.ssm = Mock()
        self.s3 = Mock()
        self.ssm.get_parameter.return_value = {"Parameter": {"Type": "SecureString", "Value": "synthetic-secret"}}
        self.context = Mock(aws_request_id="test-request")
        self.context.get_remaining_time_in_millis.return_value = 900000
        self.env = patch.dict(os.environ, {"PASSWORD_PARAMETER": "/test/password", "BACKUP_BUCKET": "test-backups"})
        self.clients = patch.object(maintenance.boto3, "client", side_effect={"ssm": self.ssm, "s3": self.s3}.__getitem__)
        self.env.start()
        self.clients.start()
        self.addCleanup(self.env.stop)
        self.addCleanup(self.clients.stop)

    def test_backup_uploads_completed_dump_and_cleans_up(self):
        paths = []

        def dump(command, **options):
            self.assertNotIn("synthetic-secret", " ".join(command))
            self.assertEqual(options["env"]["PGPASSWORD"], "synthetic-secret")
            self.assertEqual(options["env"]["PGSSLMODE"], "verify-full")
            path = Path(command[-1])
            path.write_bytes(b"PGDMP fixture")
            paths.append(path)

        def upload(path, bucket, key, **options):
            self.assertEqual(Path(path).read_bytes(), b"PGDMP fixture")
            self.assertEqual(bucket, "test-backups")
            self.assertTrue(key.startswith("telemetry/backups/"))
            self.assertTrue(key.endswith("-test-request.dump"))
            self.assertEqual(options["ExtraArgs"]["ServerSideEncryption"], "AES256")

        self.s3.upload_file.side_effect = upload
        with patch.object(maintenance.subprocess, "run", side_effect=dump):
            result = maintenance.handler({"action": "backup"}, self.context)
        self.assertEqual(result["action"], "backup")
        self.s3.upload_file.assert_called_once()
        self.assertFalse(paths[0].exists())

    def test_failed_dump_is_not_uploaded(self):
        with patch.object(maintenance.subprocess, "run", side_effect=subprocess.CalledProcessError(1, "pg_dump")):
            with self.assertRaises(subprocess.CalledProcessError):
                maintenance.handler({"action": "backup"}, self.context)
        self.s3.upload_file.assert_not_called()

    def test_vacuum_is_analyze_without_full_or_transaction(self):
        with patch.object(maintenance.subprocess, "run") as run:
            maintenance.handler({"action": "vacuum"}, self.context)
        self.assertEqual(run.call_args.args[0][-1], "VACUUM (ANALYZE);")
        self.assertTrue(run.call_args.kwargs["check"])
        self.s3.upload_file.assert_not_called()

    def test_plaintext_parameter_is_rejected(self):
        self.ssm.get_parameter.return_value["Parameter"]["Type"] = "String"
        with self.assertRaises(ValueError):
            maintenance.handler({"action": "backup"}, self.context)

    def test_invalid_action_never_reads_secret(self):
        with self.assertRaises(ValueError):
            maintenance.handler({"action": "delete"}, self.context)
        self.ssm.get_parameter.assert_not_called()


if __name__ == "__main__":
    unittest.main()
