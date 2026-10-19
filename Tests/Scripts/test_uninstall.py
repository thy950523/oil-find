import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


DEFAULT_SETTINGS = {
    "trialStartedAt": 1790000000.5, "trialLastSeenAt": 1790003600.75,
    "licenseAPI": "http://example.com", "deviceFallbackID": "legacy", "pinyinEnabled": True,
}


class UninstallTests(unittest.TestCase):
    def run_uninstall(self, arguments=(), initial=None, answer="y\n"):
        with tempfile.TemporaryDirectory(prefix="oilfind-uninstall-test-") as directory:
            root = Path(directory)
            state = root / "defaults.json"
            log = root / "calls.jsonl"
            state.write_text(json.dumps(initial if initial is not None else DEFAULT_SETTINGS))
            stub = root / "stub"
            stub.write_text("""#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
name = Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ['OILFIND_TEST_LOG'], 'a') as log:
    log.write(json.dumps([name, *args]) + '\\n')
if name == 'pgrep': sys.exit(1)
if name != 'defaults': sys.exit(0)
if args[0] != 'delete': sys.exit(1)
Path(os.environ['OILFIND_TEST_DEFAULTS']).write_text('{}')
""")
            stub.chmod(0o755)
            for name in ("defaults", "pgrep", "rm", "security", "osascript"):
                (root / name).symlink_to(stub)
            env = dict(os.environ, PATH=str(root) + os.pathsep + os.environ["PATH"],
                       OILFIND_TEST_LOG=str(log), OILFIND_TEST_DEFAULTS=str(state))
            script = Path(__file__).resolve().parents[2] / "scripts/uninstall.sh"
            result = subprocess.run(["/bin/bash", str(script), *arguments], input=answer,
                                    capture_output=True, text=True, env=env)
            calls = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
            return result, json.loads(state.read_text()), calls

    def test_default_keeps_settings_and_deletes_only_the_legacy_keychain_item(self):
        result, values, calls = self.run_uninstall()
        self.assertEqual(result.returncode, 0, result.stderr)
        # Settings are the user's. A plain uninstall must not touch them.
        self.assertEqual(values, DEFAULT_SETTINGS)
        self.assertFalse(any(call[:2] == ["defaults", "delete"] for call in calls))
        self.assertIn(["security", "delete-generic-password", "-s", "com.oiloil.find.trial"], calls)
        self.assertNotIn(["security", "delete-generic-password", "-s", "com.oiloil.find.pro.evaluation"], calls)
        deleted = sorted(argument for call in calls if call[0] == "rm"
                         for argument in call[1:] if not argument.startswith("-"))
        self.assertEqual(deleted, sorted(["/Applications/Oil Find.app",
                                          os.path.expanduser("~/Library/Application Support/Oil Find")]))

    def test_purge_removes_settings_and_the_pro_anchor(self):
        initial = {"proEvaluationStartedAt": 1790000000.5, "proEvaluationLastSeenAt": 1790003600.75,
                   "proEvaluationEndedAt": 1790003600.75, "pinyinEnabled": True}
        result, values, calls = self.run_uninstall(initial=initial)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(values, initial)
        result, values, calls = self.run_uninstall(("--purge",), initial)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(values, {})
        self.assertIn(["security", "delete-generic-password", "-s", "com.oiloil.find.pro.evaluation"], calls)
        self.assertIn(["security", "delete-generic-password", "-s", "com.oiloil.find.trial"], calls)

    def test_decline_and_invalid_arguments_do_not_mutate_anything(self):
        for arguments, answer, status in [((), "n\n", 0), (("--invalid",), "y\n", 2), (("--purge", "extra"), "y\n", 2)]:
            result, values, calls = self.run_uninstall(arguments, {"trialStartedAt": 1, "pinyinEnabled": True}, answer)
            self.assertEqual(result.returncode, status)
            self.assertEqual(values, {"trialStartedAt": 1, "pinyinEnabled": True})
            self.assertEqual(calls, [])


if __name__ == "__main__":
    unittest.main()
