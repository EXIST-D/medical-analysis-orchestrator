from __future__ import annotations

import unittest
from pathlib import Path

import yaml


REPO_ROOT = Path(__file__).resolve().parents[1]
SKILL_ROOT = REPO_ROOT / "medical-analysis-orchestrator"
MATRIX_PATH = REPO_ROOT / "tests" / "module_execution_matrix.yml"
RUNNER_PATH = REPO_ROOT / "tests" / "run_module_execution_matrix.py"


class ModuleExecutionMatrixContractTests(unittest.TestCase):
    def test_every_ready_module_has_one_real_execution_scenario(self) -> None:
        self.assertTrue(MATRIX_PATH.is_file())
        self.assertTrue(RUNNER_PATH.is_file())
        registry = yaml.safe_load(
            (SKILL_ROOT / "modules" / "registry.yml").read_text(
                encoding="utf-8-sig"
            )
        )
        matrix = yaml.safe_load(MATRIX_PATH.read_text(encoding="utf-8-sig"))
        ready = {
            item["id"] for item in registry["modules"] if item["status"] == "ready"
        }
        scenarios = matrix["modules"]
        self.assertEqual(set(scenarios), ready)
        self.assertEqual(len(scenarios), 19)
        for module_id, scenario in scenarios.items():
            with self.subTest(module=module_id):
                self.assertIn(scenario["shard"], {"core", "measurement", "clinical", "advanced"})
                self.assertTrue(scenario["dataset"])
                self.assertIsInstance(scenario["parameters"], dict)
                self.assertTrue(scenario["expected_method_id"])

    def test_ci_runs_real_execution_matrix(self) -> None:
        workflow = (
            REPO_ROOT / ".github" / "workflows" / "ci.yml"
        ).read_text(encoding="utf-8-sig")
        self.assertIn("module-execution-matrix:", workflow)
        self.assertIn("run_module_execution_matrix.py", workflow)
        for shard in ("core", "measurement", "clinical", "advanced"):
            self.assertIn(shard, workflow)


if __name__ == "__main__":
    unittest.main()
