import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[2]
INSTALLER = REPO / "scripts" / "install-portal-stack.sh"


class PortalStackInstallerTests(unittest.TestCase):
    def test_provisions_loopback_api_gateway_and_secure_handoff(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            tmp = Path(raw_tmp)
            fake_hermes = tmp / "hermes"
            calls = tmp / "hermes-calls.txt"
            fake_hermes.write_text(
                "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$PORTAL_TEST_HERMES_CALLS\"\n",
                encoding="utf-8",
            )
            fake_hermes.chmod(0o755)

            hermes_home = tmp / "hermes-home"
            app_support = tmp / "Portal"
            env = os.environ.copy()
            env.update(
                {
                    "HOME": str(tmp),
                    "PORTAL_HERMES_HOME": str(hermes_home),
                    "PORTAL_APP_SUPPORT": str(app_support),
                    "PORTAL_HERMES_BIN": str(fake_hermes),
                    "PORTAL_SKIP_HERMES_INSTALL": "1",
                    "PORTAL_SKIP_GATEWAY_HEALTHCHECK": "1",
                    "PORTAL_TEST_HERMES_CALLS": str(calls),
                }
            )

            subprocess.run(
                [
                    str(INSTALLER),
                    "--non-interactive",
                    "--skip-provider-setup",
                    "--no-open",
                ],
                cwd=REPO,
                env=env,
                check=True,
                text=True,
                capture_output=True,
            )

            env_file = hermes_home / ".env"
            values = dict(
                line.split("=", 1)
                for line in env_file.read_text(encoding="utf-8").splitlines()
                if line and not line.startswith("#") and "=" in line
            )
            self.assertEqual(values["API_SERVER_ENABLED"], "true")
            self.assertEqual(values["API_SERVER_HOST"], "127.0.0.1")
            self.assertEqual(values["API_SERVER_PORT"], "8642")
            self.assertEqual(len(values["API_SERVER_KEY"]), 64)
            self.assertEqual(stat.S_IMODE(env_file.stat().st_mode), 0o600)

            handoff = app_support / "bootstrap.json"
            payload = json.loads(handoff.read_text(encoding="utf-8"))
            self.assertEqual(payload["schemaVersion"], 1)
            self.assertEqual(payload["gatewayURL"], "ws://127.0.0.1:8642/v1/ws")
            self.assertEqual(payload["apiKey"], values["API_SERVER_KEY"])
            self.assertEqual(stat.S_IMODE(handoff.stat().st_mode), 0o600)

            self.assertEqual(
                calls.read_text(encoding="utf-8").splitlines(),
                ["gateway install --force", "gateway status --deep"],
            )

    def test_installs_the_bundled_app_for_the_current_user(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            tmp = Path(raw_tmp)
            fake_hermes = tmp / "hermes"
            fake_hermes.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            fake_hermes.chmod(0o755)
            bundled_app = tmp / "Portal.app"
            (bundled_app / "Contents").mkdir(parents=True)
            (bundled_app / "Contents" / "marker").write_text("release", encoding="utf-8")
            applications = tmp / "Applications"

            env = os.environ.copy()
            env.update(
                {
                    "HOME": str(tmp),
                    "PORTAL_HERMES_HOME": str(tmp / "hermes-home"),
                    "PORTAL_APP_SUPPORT": str(tmp / "support"),
                    "PORTAL_HERMES_BIN": str(fake_hermes),
                    "PORTAL_SKIP_HERMES_INSTALL": "1",
                    "PORTAL_SKIP_GATEWAY_HEALTHCHECK": "1",
                    "PORTAL_BUNDLED_APP": str(bundled_app),
                    "PORTAL_APPLICATIONS_DIR": str(applications),
                    "PORTAL_SKIP_APP_SIGNATURE_CHECK": "1",
                }
            )

            subprocess.run(
                [
                    str(INSTALLER),
                    "--non-interactive",
                    "--skip-provider-setup",
                    "--no-open",
                ],
                cwd=REPO,
                env=env,
                check=True,
                text=True,
                capture_output=True,
            )

            self.assertEqual(
                (applications / "Portal.app" / "Contents" / "marker").read_text(encoding="utf-8"),
                "release",
            )


if __name__ == "__main__":
    unittest.main()
