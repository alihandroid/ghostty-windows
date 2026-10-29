"""Exercise the packaging script with a fixture build, without GUI or a compiler."""

import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile


REPO = Path(__file__).resolve().parents[2]
BASH = shutil.which("bash")


@unittest.skipUnless(BASH, "bash is required")
class WindowsPackage(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="ghostty-package-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "checkout"
        self.scripts = self.root / "dist/windows"
        self.scripts.mkdir(parents=True)
        for name in ("package.sh", "verify-build.ps1"):
            shutil.copy2(REPO / "dist/windows" / name, self.scripts / name)
        (self.root / "LICENSE").write_text("fixture license")
        (self.root / ".gitignore").write_text("zig-out/\ndist/windows/_stage/\ndist/windows/*.zip\n")
        self.payload = self.root / "zig-out"
        self.files = (
            "bin/ghostty.exe", "bin/conpty.dll", "bin/OpenConsole.exe",
            "share/terminfo/ghostty.terminfo", "share/licenses/conpty/LICENSE.txt",
            "share/ghostty/themes/Fixture Theme",
            "share/ghostty/shell-integration/powershell/ghostty-shell-integration.ps1",
        )
        for name in self.files:
            path = self.payload / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("fixture " + name)
        # Bypass only compilation and the Windows verifier. The PowerShell test
        # exercises that verifier with a real executable; this tests the actual
        # shell packaging, release guards, and ZIP layout on Linux CI.
        self.commands = Path(self.temp.name) / "commands"
        self.commands.mkdir()
        for name, contents in {
            "bash": "#!/bin/sh\nexit 0\n",
            "powershell.exe": '#!/bin/sh\nprintf "%s\\n" "$PACKAGE_TEST_VERSION"\n',
            "wslpath": '#!/bin/sh\nprintf "%s\\n" "$2"\n',
        }.items():
            path = self.commands / name
            path.write_text(contents)
            path.chmod(0o755)
        if not shutil.which("zip"):
            zipper = self.commands / "zip"
            zipper.write_text(
                f"#!{sys.executable}\n"
                "import pathlib, sys, zipfile\n"
                "with zipfile.ZipFile(sys.argv[2], 'w') as archive:\n"
                "    for path in pathlib.Path(sys.argv[3]).rglob('*'):\n"
                "        if path.is_file(): archive.write(path, path.as_posix())\n"
            )
            zipper.chmod(0o755)
        self.env = dict(os.environ, PATH=str(self.commands) + os.pathsep + os.environ["PATH"],
                        PACKAGE_TEST_VERSION="1.4.0-dev+abc1234")
        self.git("init", "--quiet")
        self.git("add", ".")
        self.git("commit", "--quiet", "-m", "fixture")

    def git(self, *args):
        return subprocess.run(
            ["git", "-c", "user.name=Package Test", "-c", "user.email=package@example.invalid", *args],
            cwd=self.root, capture_output=True, text=True, check=True,
        )

    def package(self, *args):
        return subprocess.run([BASH, str(self.scripts / "package.sh"), *args],
                              cwd=self.root, env=self.env, capture_output=True, text=True)

    def test_development_zip_contains_complete_portable_layout(self):
        result = self.package()
        self.assertEqual(result.returncode, 0, result.stderr)
        archive = self.scripts / "ghostty-windows-x64-1.4.0-dev+abc1234.zip"
        with zipfile.ZipFile(archive) as package:
            names = set(package.namelist())
            for name in self.files:
                relative = name.removeprefix("bin/")
                self.assertIn("ghostty/" + relative, names)
            self.assertIn("ghostty/LICENSE", names)
            self.assertIn("ghostty/README.txt", names)
            self.assertIn("1.4.0-dev+abc1234", package.read("ghostty/README.txt").decode())
        self.assertFalse((self.scripts / "_stage").exists())

    def test_missing_resources_fail_before_producing_zip(self):
        for name in self.files:
            with self.subTest(name=name):
                path = self.payload / name
                contents = path.read_bytes()
                path.unlink()
                try:
                    result = self.package()
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("Incomplete Windows build", result.stderr)
                    self.assertFalse(list(self.scripts.glob("*.zip")))
                finally:
                    path.write_bytes(contents)

    def test_version_failure_does_not_fall_back_to_a_git_tag(self):
        self.env["PACKAGE_TEST_VERSION"] = ""
        result = self.package()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("semantic executable version", result.stderr)
        self.assertFalse(list(self.scripts.glob("*.zip")))

    def test_release_requires_exact_annotated_tag_and_clean_tree(self):
        result = self.package("--release")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("exact annotated", result.stderr)
        self.git("tag", "win-v1.4.0")
        result = self.package("--release")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("exact annotated", result.stderr)
        self.git("tag", "-d", "win-v1.4.0")
        self.git("tag", "-a", "win-v1.4.0", "-m", "fixture release")
        (self.root / "LICENSE").write_text("modified license")
        result = self.package("--release")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("clean working tree", result.stderr)

    def test_release_rejects_wrong_binary_version_and_packages_matching_version(self):
        self.git("tag", "-a", "win-v1.4.0", "-m", "fixture release")
        result = self.package("--release")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not match release tag", result.stderr)
        self.env["PACKAGE_TEST_VERSION"] = "1.4.0"
        result = self.package("--release")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.scripts / "ghostty-windows-x64-1.4.0.zip").is_file())

    def test_release_rejects_debug_optimization(self):
        result = self.package("debug", "--release")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("fast optimization", result.stderr)


if __name__ == "__main__":
    unittest.main()
