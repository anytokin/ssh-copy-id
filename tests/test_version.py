import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

from ssh_copy_id.version import __version__, get_version


class VersionTests(unittest.TestCase):
    def test_version_is_available(self):
        self.assertRegex(get_version(), r"^\d+\.\d+\.\d+")
        self.assertEqual(get_version(), __version__)

    def test_version_works_without_repository_or_site_packages(self):
        source = Path(__file__).resolve().parents[1] / "src" / "ssh_copy_id" / "version.py"
        with tempfile.TemporaryDirectory() as directory:
            module_path = Path(directory) / "version.py"
            shutil.copyfile(source, module_path)
            # A wheel or frozen executable does not include pyproject.toml.
            # Isolated mode also ensures no installed TOML backport is required.
            script = (
                "import json, runpy, sys; "
                "sys.frozen = True; "
                "module = runpy.run_path(sys.argv[1]); "
                "print(json.dumps(module['get_version']()))"
            )
            result = subprocess.run(
                [sys.executable, "-I", "-S", "-c", script, str(module_path)],
                cwd=directory,
                capture_output=True,
                text=True,
                check=True,
            )
        self.assertEqual(json.loads(result.stdout), __version__)


if __name__ == "__main__":
    unittest.main()
