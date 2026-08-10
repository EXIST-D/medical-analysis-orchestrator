"""Tests for the R-first figure planning and artifact QA boundary."""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import yaml


SKILL_ROOT = Path(__file__).resolve().parents[1]
SCRIPT_DIR = SKILL_ROOT / "scripts"


class FigureOrchestrationTests(unittest.TestCase):
    def test_ready_modules_all_have_a_figure_plan_family(self) -> None:
        from plan_figures import MODULE_ROLES

        ready = []
        for manifest_path in (SKILL_ROOT / "modules").glob("*/module.yml"):
            manifest = yaml.safe_load(manifest_path.read_text(encoding="utf-8")) or {}
            if manifest.get("status") == "ready":
                ready.append(str(manifest.get("id")))
        self.assertGreaterEqual(len(ready), 19)
        self.assertEqual(set(ready) - set(MODULE_ROLES), set())

    def test_plan_is_deterministically_module_aware(self) -> None:
        from plan_figures import build_plan

        plan = build_plan(
            {
                "analysis": {"modules": ["descriptive", "logistic-regression", "network"]},
                "reporting": {"figure_contract": {"template": "medical-academic-v1"}},
            },
            {"n_rows": 120, "n_columns": 8},
        )
        self.assertEqual([item["recommended_figure"] for item in plan["modules"]], [
            "grouped_distribution_and_summary", "roc_and_calibration", "network_with_stability_boundary"
        ])
        self.assertIn("dual_y_axis", plan["guardrails"])

    def test_qa_rejects_non_r_and_missing_source_artifact(self) -> None:
        from figure_visual_qa import audit

        with tempfile.TemporaryDirectory() as temporary:
            run_dir = Path(temporary)
            result_path = run_dir / "analysis_results.json"
            output_path = run_dir / "figure_visual_qa.json"
            result_path.write_text(json.dumps({"descriptive": {"figures": [{
                "figure_id": "bad", "generated_by": "Python", "statistics": {},
                "conclusion": "", "evidence_role": "", "preview_path": "missing.png", "exports": []
            }]}}, ensure_ascii=False), encoding="utf-8")
            report = audit(run_dir, result_path, output_path, False, 300)
            self.assertEqual(report["status"], "fail")
            self.assertTrue(output_path.is_file())

    def test_cli_script_compiles(self) -> None:
        completed = subprocess.run(
            [sys.executable, "-m", "py_compile", str(SCRIPT_DIR / "plan_figures.py"), str(SCRIPT_DIR / "figure_visual_qa.py")],
            capture_output=True, text=True, check=False,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
