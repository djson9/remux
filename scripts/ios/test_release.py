import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import release


class ReleaseTest(unittest.TestCase):
    def test_failed_verification_never_packages_or_publishes(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            repo = root / "repo"
            repo.mkdir()
            pin = "b" * 40
            (repo / ".apple-signing-tools-version").write_text(pin)
            output = root / "output"
            output.mkdir()

            def failed_lane(*args, **kwargs):
                result = Path(args[args.index("--result") + 1])
                result.write_text(json.dumps({"status": "failed", "error": {"code": "artifact_verification_failed"}}))

            with patch.object(release, "REPO", repo), patch.object(Path, "home", return_value=root), \
                 patch.dict(os.environ, {"REMUX_PROFILE_UUID": "existing-profile", "DEVICE_UDID": "phone"}), \
                 patch.object(release.subprocess, "check_output", side_effect=["", "a" * 40, pin, ""]), \
                 patch.object(release.tempfile, "mkdtemp", return_value=str(output)), \
                 patch.object(release, "run", side_effect=failed_lane) as command, \
                 patch.object(release, "package") as package:
                with self.assertRaisesRegex(RuntimeError, "Signing failed"):
                    release.release("101", publish=True)
                command.assert_called_once()
                package.assert_not_called()
                self.assertFalse((root / ".local/share/remux/releases/101/package").exists())


if __name__ == "__main__":
    unittest.main()
