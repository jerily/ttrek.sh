"""Verify production archive pruning without building native dependencies."""
import importlib.util
from pathlib import Path
import stat
import tempfile
import unittest
import zipfile


SPEC = importlib.util.spec_from_file_location(
    "finalize_lambda", Path(__file__).resolve().parent.parent / "devops/finalize-lambda.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class FinalizeTests(unittest.TestCase):
    def archive(self, path, bootstrap=True):
        files = {
            "bootstrap": b"bootstrap", "local/bin/tclsh": b"tclsh",
            "etc/config.ini": b"config", "etc/releases.json": b"{}",
            "content/blog/post.md": b"![Header](images/header.jpg)",
            "content/blog/images/header.jpg": b"jpeg",
            "content/blog/images/header-orig.png": b"original",
            "content/docs/nested/diagram.SVG": b"svg",
            "public/favicon.ico": b"favicon", "local/lib/icon.png": b"package icon",
        }
        if not bootstrap:
            del files["bootstrap"]
        files["etc/content-snapshot.data"] = b"prepared records"
        with zipfile.ZipFile(path, "w") as archive:
            for name, data in files.items():
                archive.writestr(name, data)
        return files

    def test_removes_content_images_preserves_other_bytes_and_sets_modes(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "site.zip"
            files = self.archive(path)
            MODULE.finalize(path)
            MODULE.finalize(path)  # Finalization is repeatable.
            with zipfile.ZipFile(path) as archive:
                expected = {name for name in files if not name.startswith("content/") and name != "etc/content-snapshot.data"}
                self.assertEqual(set(archive.namelist()), expected)
                for name in expected:
                    self.assertEqual(archive.read(name), files[name])
                for name in ("bootstrap", "local/bin/tclsh"):
                    self.assertEqual(stat.S_IMODE(archive.getinfo(name).external_attr >> 16), 0o755)

    def test_missing_bootstrap_leaves_archive_untouched(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "site.zip"
            self.archive(path, bootstrap=False)
            original = path.read_bytes()
            with self.assertRaises(KeyError):
                MODULE.finalize(path)
            self.assertEqual(path.read_bytes(), original)
            self.assertEqual(list(Path(directory).iterdir()), [path])


if __name__ == "__main__":
    unittest.main()
