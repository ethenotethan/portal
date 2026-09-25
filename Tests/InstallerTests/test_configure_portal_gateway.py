import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[2]
HELPER = REPO / "scripts" / "configure-portal-gateway.py"


class ConfigurePortalGatewayTests(unittest.TestCase):
    def run_helper(self, *args: str) -> subprocess.CompletedProcess:
        return subprocess.run(
            [sys.executable, str(HELPER), *args],
            text=True,
            capture_output=True,
            check=False,
        )

    def test_configure_creates_private_env_without_leaking_key(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            env_file = Path(raw_tmp) / ".env"
            result = self.run_helper("configure", "--env-file", str(env_file))
            self.assertEqual(result.returncode, 0, result.stderr)
            values = dict(
                line.split("=", 1)
                for line in env_file.read_text(encoding="utf-8").splitlines()
                if line and not line.startswith("#") and "=" in line
            )
            key = values["API_SERVER_KEY"]
            self.assertRegex(key, r"^[0-9a-f]{64}$")
            self.assertEqual(values["API_SERVER_HOST"], "127.0.0.1")
            self.assertEqual(stat.S_IMODE(env_file.stat().st_mode), 0o600)
            self.assertNotIn(key, result.stdout + result.stderr)

    def test_handoff_reuses_env_key_and_is_private(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            root = Path(raw_tmp)
            env_file = root / ".env"
            handoff = root / "bootstrap.json"
            key = "ab" * 32
            env_file.write_text(
                f"API_SERVER_KEY={key}\nAPI_SERVER_HOST=127.0.0.1\nAPI_SERVER_PORT=9753\n",
                encoding="utf-8",
            )
            env_file.chmod(0o600)
            result = self.run_helper(
                "handoff",
                "--env-file",
                str(env_file),
                "--handoff-file",
                str(handoff),
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            payload = json.loads(handoff.read_text(encoding="utf-8"))
            self.assertEqual(payload["apiKey"], key)
            self.assertEqual(payload["gatewayURL"], "ws://127.0.0.1:9753/v1/ws")
            self.assertEqual(stat.S_IMODE(handoff.stat().st_mode), 0o600)

    def test_configure_refuses_symlink_env(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            root = Path(raw_tmp)
            target = root / "target"
            target.write_text("DO_NOT_TOUCH=1\n", encoding="utf-8")
            env_file = root / ".env"
            env_file.symlink_to(target)
            result = self.run_helper("configure", "--env-file", str(env_file))
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(target.read_text(encoding="utf-8"), "DO_NOT_TOUCH=1\n")


if __name__ == "__main__":
    unittest.main()
