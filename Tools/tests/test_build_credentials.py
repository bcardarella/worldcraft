import contextlib
import io
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from embed_build_credentials import embed
from check_publication import inspect_bytes, private_path


class BuildCredentialsTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.environment = {"TARGET_BUILD_DIR": self.directory.name,
                            "UNLOCALIZED_RESOURCES_FOLDER_PATH": "Worldcraft.app"}
        (Path(self.directory.name) / "Worldcraft.app").mkdir()

    def test_environment_only_and_keys_never_printed(self):
        self.environment.update(TYPESAFE_API_KEY="test-typesafe-<&\"'$", OPENROUTER_API_KEY="test-router-secret")
        captured = io.StringIO()
        with contextlib.redirect_stdout(captured), contextlib.redirect_stderr(captured):
            path = embed(self.environment)
        self.assertEqual(captured.getvalue(), "")
        self.assertEqual(plistlib.loads(path.read_bytes()), {
            name: self.environment[name] for name in ("TYPESAFE_API_KEY", "OPENROUTER_API_KEY")})
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_incremental_build_rotates_then_removes_keys_and_legacy_files(self):
        self.environment["TYPESAFE_API_KEY"] = "test-old-typesafe"
        path = embed(self.environment)
        for name in ("TypeSafe.local.plist", "OpenRouter.local.plist"):
            (path.parent / name).write_text("test-legacy-secret")
        self.environment["TYPESAFE_API_KEY"] = "test-new-typesafe"
        self.environment["OPENROUTER_API_KEY"] = "test-new-router"
        embed(self.environment)
        self.assertNotIn(b"test-old-typesafe", path.read_bytes())
        self.assertEqual(plistlib.loads(path.read_bytes())["TYPESAFE_API_KEY"], "test-new-typesafe")
        self.assertFalse((path.parent / "TypeSafe.local.plist").exists())
        self.assertFalse((path.parent / "OpenRouter.local.plist").exists())
        del self.environment["TYPESAFE_API_KEY"]
        del self.environment["OPENROUTER_API_KEY"]
        embed(self.environment)
        self.assertEqual(plistlib.loads(path.read_bytes()), {})

    def test_invalid_key_removes_previous_resource_without_disclosing_key(self):
        self.environment["TYPESAFE_API_KEY"] = "test-old-key"
        path = embed(self.environment)
        self.environment["TYPESAFE_API_KEY"] = "test-invalid key"
        process = subprocess.run([sys.executable, str(Path(__file__).resolve().parents[1] / "embed_build_credentials.py")],
                                 env=self.environment, capture_output=True, text=True)
        self.assertEqual(process.returncode, 1)
        self.assertNotIn("test-invalid", process.stdout + process.stderr)
        self.assertFalse(path.exists())

    def test_rejects_output_outside_app_build_directory(self):
        for relative in ("../outside.app", "", "source", "Missing.app"):
            self.environment["UNLOCALIZED_RESOURCES_FOLDER_PATH"] = relative
            with self.assertRaises(ValueError):
                embed(self.environment)

    def test_publication_audit_rejects_private_values_and_paths(self):
        token = b"sk-or-v1-" + b"a" * 64
        self.assertIn("API token pattern", inspect_bytes(token, set()))
        self.assertTrue(inspect_bytes(b"arbitrary-secret", {b"arbitrary-secret"}))
        team = b"A1B2C3D4E5"
        self.assertIn("literal Apple developer team", inspect_bytes(b"DEVELOPMENT_TEAM = " + team, set()))
        self.assertTrue(private_path("Config/Signing.local.xcconfig"))
        self.assertTrue(private_path("tmp/Build/Worldcraft.app/Info.plist"))
        self.assertTrue(private_path("com.apple.DeveloperTools/Xcode/CachedSpecifications-xcodebuild"))
        self.assertFalse(private_path("Config/Signing.example.xcconfig"))
        self.assertFalse(private_path("Worldcraft.xcodeproj/xcshareddata/xcschemes/Worldcraft.xcscheme"))


if __name__ == "__main__":
    unittest.main()
