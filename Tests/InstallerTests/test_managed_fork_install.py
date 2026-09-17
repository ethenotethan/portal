import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[2]
INSTALLER = REPO / "scripts" / "install-portal-stack.sh"


class ManagedForkInstallTests(unittest.TestCase):
    def test_installs_pinned_fork_and_preserves_key_on_rerun(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            root = Path(raw_tmp)
            home = root / "home"
            home.mkdir()
            checkout = root / "fake-harness"
            (checkout / "scripts").mkdir(parents=True)
            log = root / "calls.log"
            fake_hermes = root / "fake-hermes"
            fake_hermes.write_text(
                "#!/bin/sh\nprintf 'hermes %s\\n' \"$*\" >> \"$PORTAL_TEST_LOG\"\n",
                encoding="utf-8",
            )
            fake_hermes.chmod(0o755)
            install_script = checkout / "scripts" / "install.sh"
            install_script.write_text(
                "#!/bin/sh\n"
                "set -eu\n"
                "mkdir -p \"$PORTAL_INSTALL_ROOT/venv/bin\"\n"
                "cp \"$PORTAL_FAKE_HERMES\" \"$PORTAL_INSTALL_ROOT/venv/bin/hermes\"\n"
                "chmod 755 \"$PORTAL_INSTALL_ROOT/venv/bin/hermes\"\n"
                "printf 'install %s\\n' \"$*\" >> \"$PORTAL_TEST_LOG\"\n",
                encoding="utf-8",
            )
            install_script.chmod(0o755)

            install_root = home / "managed-hermes"
            hermes_home = home / "hermes-home"
            app_support = home / "support"
            env = os.environ.copy()
            env.update(
                {
                    "HOME": str(home),
                    "PORTAL_INSTALLER_TESTING": "1",
                    "PORTAL_TEST_SOURCE": str(checkout),
                    "PORTAL_FAKE_HERMES": str(fake_hermes),
                    "PORTAL_TEST_LOG": str(log),
                    "PORTAL_INSTALL_ROOT": str(install_root),
                    "PORTAL_HERMES_HOME": str(hermes_home),
                    "PORTAL_APP_SUPPORT": str(app_support),
                    "PORTAL_SKIP_GATEWAY_HEALTHCHECK": "1",
                }
            )
            command = [
                str(INSTALLER),
                "--non-interactive",
                "--skip-provider-setup",
                "--no-open",
            ]

            first = subprocess.run(command, cwd=REPO, env=env, text=True, capture_output=True)
            self.assertEqual(first.returncode, 0, first.stderr)
            handoff = app_support / "bootstrap.json"
            env_file = hermes_home / ".env"
            key = json.loads(handoff.read_text(encoding="utf-8"))["apiKey"]
            self.assertEqual(stat.S_IMODE(env_file.stat().st_mode), 0o600)
            self.assertNotIn(key, first.stdout + first.stderr)

            calls = log.read_text(encoding="utf-8")
            self.assertIn("--commit", calls)
            self.assertIn("--force-commit", calls)
            self.assertIn("hermes gateway install --force", calls)
            self.assertIn("hermes gateway status --deep", calls)

            second = subprocess.run(command, cwd=REPO, env=env, text=True, capture_output=True)
            self.assertEqual(second.returncode, 0, second.stderr)
            self.assertEqual(json.loads(handoff.read_text(encoding="utf-8"))["apiKey"], key)


if __name__ == "__main__":
    unittest.main()
