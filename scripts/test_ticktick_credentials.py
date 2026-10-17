import os
import pathlib
import plistlib
import subprocess
import sys
import tempfile
import unittest


SCRIPT = pathlib.Path(__file__).with_name("stamp-ticktick-credentials.py")


class TickTickCredentialStampTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)
        self.plist = self.root / "Info.plist"
        self.plist.write_bytes(plistlib.dumps({"CFBundleIdentifier": "com.dbrief.app"}))

    def stamp(self, env=None, secrets=None):
        arguments = [sys.executable, str(SCRIPT), str(self.plist)]
        if secrets is not None:
            path = self.root / "secrets.env"
            path.write_text(secrets)
            arguments.append(str(path))
        environment = {k: v for k, v in os.environ.items() if not k.startswith("TICKTICK_")}
        environment.update(env or {})
        return subprocess.run(arguments, capture_output=True, text=True, env=environment, check=True)

    def values(self):
        info = plistlib.loads(self.plist.read_bytes())
        return info.get("DBTickTickClientID"), info.get("DBTickTickClientSecret")

    def test_missing_credentials_write_empty_keys(self):
        self.stamp(secrets=None)
        self.assertEqual(self.values(), ("", ""))

    def test_environment_values_are_written_and_never_printed(self):
        result = self.stamp(env={"TICKTICK_CLIENT_ID": "id-1", "TICKTICK_CLIENT_SECRET": "secret-1"})
        self.assertEqual(self.values(), ("id-1", "secret-1"))
        self.assertNotIn("secret-1", result.stdout + result.stderr)

    def test_secrets_file_fills_missing_values_and_environment_wins(self):
        self.stamp(env={"TICKTICK_CLIENT_ID": "from-env"},
                   secrets="# local only\nTICKTICK_CLIENT_ID=from-file\nTICKTICK_CLIENT_SECRET='file secret'\n")
        self.assertEqual(self.values(), ("from-env", "file secret"))

    def test_missing_secrets_file_is_not_an_error(self):
        subprocess.run([sys.executable, str(SCRIPT), str(self.plist), str(self.root / "absent.env")],
                       check=True, capture_output=True,
                       env={k: v for k, v in os.environ.items() if not k.startswith("TICKTICK_")})
        self.assertEqual(self.values(), ("", ""))

    def test_other_keys_are_preserved(self):
        self.stamp(env={"TICKTICK_CLIENT_ID": "a", "TICKTICK_CLIENT_SECRET": "b"})
        self.assertEqual(plistlib.loads(self.plist.read_bytes())["CFBundleIdentifier"], "com.dbrief.app")


if __name__ == "__main__":
    unittest.main()
