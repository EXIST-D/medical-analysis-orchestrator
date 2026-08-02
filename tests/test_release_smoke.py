from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import yaml


REPO_ROOT = Path(__file__).resolve().parents[1]
SKILL_ROOT = REPO_ROOT / "medical-analysis-orchestrator"
SCRIPTS = SKILL_ROOT / "scripts"


class ReleaseSmokeTests(unittest.TestCase):
    def test_registry_descriptors_and_runtime_scripts_are_present(self) -> None:
        registry = yaml.safe_load((SKILL_ROOT / "modules" / "registry.yml").read_text(encoding="utf-8"))
        self.assertEqual(len(registry["modules"]), 19)
        for module in registry["modules"]:
            module_root = SKILL_ROOT / "modules" / module["id"]
            descriptor_path = module_root / "module.yml"
            self.assertTrue(descriptor_path.is_file(), module["id"])
            descriptor = yaml.safe_load(descriptor_path.read_text(encoding="utf-8"))
            self.assertEqual(module["status"], "ready", module["id"])
            self.assertEqual(descriptor["status"], "ready", module["id"])
            self.assertTrue((module_root / descriptor["entrypoint"]).is_file(), module["id"])
        for name in (
            "detect_python_environment.py", "install_python_packages.py", "manage_renv.R",
            "write_environment_manifest.py", "verify_visual_regression.py", "generate_audit_report.py",
        ):
            self.assertTrue((SCRIPTS / name).is_file(), name)

    def test_python_format_capability_probe_for_csv(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "input.csv"
            source.write_text("id,score\n1,2\n", encoding="utf-8")
            output = root / "python_environment.json"
            completed = subprocess.run(
                [sys.executable, str(SCRIPTS / "detect_python_environment.py"), "--input", str(source), "--output", str(output)],
                capture_output=True, text=True, encoding="utf-8", errors="replace", check=False,
            )
            self.assertEqual(completed.returncode, 0, completed.stderr or completed.stdout)
            profile = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual(profile["input_format"], "csv")
            self.assertTrue((root / "python_requirements.lock.json").is_file())

    def test_visual_regression_reports_renderer_capability_honestly(self) -> None:
        spec = importlib.util.spec_from_file_location("visual_regression", SCRIPTS / "verify_visual_regression.py")
        assert spec and spec.loader
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        value = module.soffice_path()
        self.assertTrue(value is None or Path(value).is_file())


if __name__ == "__main__":
    unittest.main()
