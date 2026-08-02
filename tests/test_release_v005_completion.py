from __future__ import annotations

import re
import unittest
from pathlib import Path

import yaml


REPO_ROOT = Path(__file__).resolve().parents[1]
SKILL_ROOT = REPO_ROOT / "medical-analysis-orchestrator"


class ReleaseV005CompletionTests(unittest.TestCase):
    def test_every_production_figure_module_uses_medical_academic_palette(self) -> None:
        plotting_modules: list[str] = []
        missing_template_usage: list[str] = []
        for analysis_path in sorted((SKILL_ROOT / "modules").glob("*/analysis.R")):
            implementation = analysis_path.read_text(encoding="utf-8-sig")
            if "export_r_figure(" not in implementation:
                continue
            module_id = analysis_path.parent.name
            plotting_modules.append(module_id)
            if not re.search(
                r"medical_figure_(?:palette|colors)\s*\(", implementation
            ):
                missing_template_usage.append(module_id)

        self.assertEqual(len(plotting_modules), 12)
        self.assertEqual(missing_template_usage, [])

        shared = (
            SKILL_ROOT / "modules" / "_shared" / "module_utils.R"
        ).read_text(encoding="utf-8-sig")
        self.assertIn("apply_medical_base_figure_template <- function", shared)
        self.assertIn("template = settings$template", shared)

    def test_readme_declares_default_figure_for_every_ready_module(self) -> None:
        readme = (REPO_ROOT / "README.md").read_text(encoding="utf-8-sig")
        self.assertIn("| 模块 | 当前能力 | 默认图形 | 状态 |", readme)

        registry = yaml.safe_load(
            (SKILL_ROOT / "modules" / "registry.yml").read_text(
                encoding="utf-8-sig"
            )
        )
        for entry in registry["modules"]:
            descriptor = yaml.safe_load(
                (
                    SKILL_ROOT / "modules" / entry["id"] / "module.yml"
                ).read_text(encoding="utf-8-sig")
            )
            figures = descriptor.get("outputs", {}).get("figures", [])
            expected = "是：" + "；".join(figures) if figures else "不默认生成"
            row_pattern = re.compile(
                rf"^\|\s*`{re.escape(entry['id'])}`\s*\|.*\|\s*{re.escape(expected)}\s*\|\s*`ready`\s*\|$",
                re.MULTILINE,
            )
            self.assertRegex(readme, row_pattern, entry["id"])

    def test_distribution_and_packaging_automation_exists(self) -> None:
        self.assertTrue((REPO_ROOT / "tools" / "check_distribution_sync.py").is_file())
        self.assertTrue((REPO_ROOT / "tools" / "package_release.py").is_file())
        self.assertTrue((REPO_ROOT / "release-manifest.json").is_file())

    def test_windows_module_matrix_forces_binary_r_packages(self) -> None:
        workflow = (REPO_ROOT / ".github" / "workflows" / "ci.yml").read_text(
            encoding="utf-8-sig"
        )
        self.assertIn('type = "binary"', workflow)
        self.assertIn('Sys.getenv("RSPM")', workflow)

    def test_release_tree_contains_no_runtime_artifacts(self) -> None:
        forbidden_names = {"Rplots.pdf", ".coverage"}
        forbidden_directories = {".r-library"}
        problems: list[str] = []
        for path in REPO_ROOT.rglob("*"):
            if ".git" in path.parts:
                continue
            if path.name in forbidden_names:
                problems.append(str(path.relative_to(REPO_ROOT)))
            if path.is_dir() and path.name in forbidden_directories:
                problems.append(str(path.relative_to(REPO_ROOT)))
        self.assertEqual(problems, [])


if __name__ == "__main__":
    unittest.main()
