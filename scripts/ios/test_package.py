import json
import plistlib
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from package import package
from publish import publish


class PackageTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.info = {"CFBundleVersion": "42", "CFBundleIdentifier": "com.davidjson.remux", "CFBundleShortVersionString": "0.1.0"}
        self.write_info()
        (self.root / "Remux.ipa").write_bytes(b"verified test ipa")

    def write_info(self):
        (self.root / "Info.plist").write_bytes(plistlib.dumps(self.info))

    def test_installer_and_manifest_target_immutable_build(self):
        metadata = package(self.root, "https://example.test:8473", "a" * 40)
        manifest = plistlib.loads((self.root / "manifest.plist").read_bytes())
        self.assertEqual(manifest["items"][0]["assets"][0]["url"], "https://example.test:8473/42/Remux.ipa")
        self.assertEqual(metadata["sourceRevision"], "a" * 40)
        self.assertIn("itms-services://?action=download-manifest&amp;url=https%3A%2F%2Fexample.test%3A8473%2F42%2Fmanifest.plist", (self.root / "index.html").read_text())
        self.assertFalse((self.root / "Info.plist").exists())

    def test_rejects_wrong_app(self):
        self.info["CFBundleIdentifier"] = "dev.remux.app"
        self.write_info()
        with self.assertRaises(ValueError):
            package(self.root, "https://example.test", "a" * 40)

    def test_rejects_insecure_or_authenticated_url(self):
        for url in ("http://example.test", "https://secret@example.test", "https://example.test?token=secret"):
            with self.subTest(url=url), self.assertRaises(ValueError):
                package(self.root, url, "a" * 40)

    @patch("publish.subprocess.run")
    def test_tampered_ipa_is_rejected_before_publication(self, command):
        package(self.root, "https://example.test", "a" * 40)
        (self.root / "Remux.ipa").write_bytes(b"tampered")
        with self.assertRaisesRegex(ValueError, "checksum mismatch"), patch("publish.shutil.copyfile") as copy:
            publish(self.root, "/mnt/b2/remux-ios-ota", "https://example.test")
        copy.assert_not_called()


if __name__ == "__main__":
    unittest.main()
