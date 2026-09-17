import os
from pathlib import Path
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[2]
PACKAGER = REPO / "scripts" / "build-macos-installer.sh"


class MacOSInstallerPackagerTests(unittest.TestCase):
    def test_packages_app_and_setup_command_into_dmg(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            tmp = Path(raw_tmp)
            app = tmp / "Portal.app"
            (app / "Contents").mkdir(parents=True)
            (app / "Contents" / "marker").write_text("release", encoding="utf-8")
            output = tmp / "Portal.dmg"
            fake_bin = tmp / "bin"
            fake_bin.mkdir()
            (fake_bin / "codesign").write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            (fake_bin / "hdiutil").write_text(
                "#!/bin/sh\nfor arg in \"$@\"; do out=\"$arg\"; done\n: > \"$out\"\n",
                encoding="utf-8",
            )
            (fake_bin / "codesign").chmod(0o755)
            (fake_bin / "hdiutil").chmod(0o755)
            env = os.environ.copy()
            env["PATH"] = f"{fake_bin}:{env['PATH']}"
            env["PORTAL_KEEP_INSTALLER_STAGE"] = "1"

            subprocess.run(
                [str(PACKAGER), "--app", str(app), "--output", str(output)],
                cwd=REPO,
                env=env,
                check=True,
                text=True,
                capture_output=True,
            )

            stage = output.with_suffix(".stage")
            self.assertEqual(
                (stage / "Portal.app" / "Contents" / "marker").read_text(encoding="utf-8"),
                "release",
            )
            self.assertTrue((stage / "Set Up Portal.command").stat().st_mode & 0o111)
            self.assertTrue((stage / "configure-portal-gateway.py").is_file())
            self.assertTrue((stage / "README.txt").is_file())
            self.assertTrue(output.is_file())


if __name__ == "__main__":
    unittest.main()
