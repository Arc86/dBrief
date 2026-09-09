import pathlib
import plistlib
import subprocess
import sys
import tempfile
import unittest


SCRIPT = pathlib.Path(__file__).with_name("stamp-beta-build.py")


class BetaBuildTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)
        self.counter = self.root / "counter"
        self.counter.write_text("0\n")
        self.plist = self.root / "Info.plist"
        self.original = {
            "CFBundleIdentifier": "com.dbrief.app.beta",
            "CFBundleShortVersionString": "1.3.9",
            "CFBundleVersion": "1.3.9",
        }
        self.plist.write_bytes(plistlib.dumps(self.original))

    def stamp(self):
        return subprocess.run(
            [sys.executable, str(SCRIPT), str(self.plist), str(self.counter)],
            capture_output=True, text=True,
        )

    def test_each_beta_build_advances_without_changing_app_version(self):
        for expected in (1, 2):
            # Packaging starts from the production source plist every time.
            self.plist.write_bytes(plistlib.dumps(self.original))
            result = self.stamp()
            self.assertEqual(result.returncode, 0, result.stderr)
            info = plistlib.loads(self.plist.read_bytes())
            self.assertEqual(info["CFBundleVersion"], str(expected))
            self.assertEqual(info["CFBundleShortVersionString"], "1.3.9")
            self.assertEqual(int(self.counter.read_text()), expected)

    def test_production_bundle_is_rejected_without_consuming_number(self):
        self.original["CFBundleIdentifier"] = "com.dbrief.app"
        self.plist.write_bytes(plistlib.dumps(self.original))
        before = self.plist.read_bytes()
        result = self.stamp()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.plist.read_bytes(), before)
        self.assertEqual(self.counter.read_text(), "0\n")

    def test_invalid_counter_never_resets_or_changes_bundle(self):
        for bad in ("", "-1", "1.3.9", "corrupt"):
            with self.subTest(counter=bad):
                self.counter.write_text(bad)
                before = self.plist.read_bytes()
                self.assertNotEqual(self.stamp().returncode, 0)
                self.assertEqual(self.counter.read_text(), bad)
                self.assertEqual(self.plist.read_bytes(), before)

    def test_missing_counter_fails_instead_of_reusing_build_one(self):
        self.counter.unlink()
        before = self.plist.read_bytes()
        self.assertNotEqual(self.stamp().returncode, 0)
        self.assertFalse(self.counter.exists())
        self.assertEqual(self.plist.read_bytes(), before)


if __name__ == "__main__":
    unittest.main()
