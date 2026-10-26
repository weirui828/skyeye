"""Exercise installer cancellation without touching a real app or running service."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class InstallerTests(unittest.TestCase):
    def run_install(self, outcome):
        self.temp = tempfile.TemporaryDirectory(prefix="skyeye-installer-test-")
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        (root / "scripts").mkdir()
        installer = Path(__file__).resolve().parents[1] / "install.sh"
        shutil.copyfile(installer, root / "scripts/install.sh")
        build = root / "build/SkyEye.app"
        build.mkdir(parents=True)
        (build / "new-app").write_text("new")
        destination = root / "Applications"
        (destination / "SkyEye.app").mkdir(parents=True)
        (destination / "SkyEye.app/old-app").write_text("old")
        marker = root / "running"
        marker.touch()
        fake = root / "fake-bin"
        fake.mkdir()
        commands = {
            "pgrep": 'test -f "$RUNNING_MARKER"',
            "osascript": 'if [ "$QUIT_OUTCOME" = cancel ]; then exit 1; fi\n'
                         'if [ "$QUIT_OUTCOME" = success ]; then rm "$RUNNING_MARKER"; fi',
            "sleep": "exit 0",
            "open": 'touch "$OPEN_MARKER"',
            "pkill": 'touch "$KILL_MARKER"; exit 99',
        }
        for name, body in commands.items():
            file = fake / name
            file.write_text("#!/bin/bash\n" + body + "\n")
            file.chmod(0o755)
        builder = root / "scripts/build.sh"
        builder.write_text("#!/bin/bash\nexit 0\n")
        builder.chmod(0o755)
        env = dict(os.environ, DEST=str(destination), BIN_DIR=str(root / "bin"),
                   PATH=str(fake) + os.pathsep + os.environ["PATH"],
                   QUIT_OUTCOME=outcome, RUNNING_MARKER=str(marker),
                   OPEN_MARKER=str(root / "opened"), KILL_MARKER=str(root / "killed"))
        result = subprocess.run(["/bin/bash", str(root / "scripts/install.sh")],
                                env=env, text=True, capture_output=True, timeout=10)
        self.assertFalse((root / "killed").exists(), "Installer must never force-quit")
        return result, root, destination

    def test_cancel_preserves_installed_app(self):
        result, root, destination = self.run_install("cancel")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((destination / "SkyEye.app/old-app").exists())
        self.assertFalse((root / "opened").exists())
        self.assertFalse((root / "bin").exists())

    def test_still_running_preserves_installed_app(self):
        result, root, destination = self.run_install("still-running")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((destination / "SkyEye.app/old-app").exists())
        self.assertFalse((root / "opened").exists())

    def test_success_installs_and_links_tools(self):
        result, root, destination = self.run_install("success")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((destination / "SkyEye.app/new-app").exists())
        self.assertTrue((root / "opened").exists())
        self.assertTrue((root / "bin/sky").is_symlink())
        self.assertTrue((root / "bin/skyeye-mcp").is_symlink())


if __name__ == "__main__":
    unittest.main()
