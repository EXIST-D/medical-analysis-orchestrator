"""Regression tests for the academic manuscript reporting contract."""

from __future__ import annotations

import sys
import unittest
import shutil
from pathlib import Path


SKILL_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SKILL_ROOT / "scripts"))

from build_report import (  # noqa: E402
    build_artifact_commentary,
    build_academic_manuscript_outline,
    prepare_article_table_rows,
    table_reference_level_note,
    write_reporting_supplements,
)


class AcademicManuscriptContractTests(unittest.TestCase):
    def setUp(self) -> None:
        self.artifact_dir = SKILL_ROOT / "tests" / "_report_contract_artifacts"
        if self.artifact_dir.exists():
            shutil.rmtree(self.artifact_dir)

    def tearDown(self) -> None:
        if self.artifact_dir.exists():
            shutil.rmtree(self.artifact_dir)

    def test_default_outline_has_journal_sections_and_safe_background(self) -> None:
        plan = {
            "research": {
                "primary_question": "治疗分组与随访评分及临床结局是否相关？",
                "design": "observational cohort",
            },
            "variables": {"outcomes": {"primary": "score_followup"}},
        }

        outline = build_academic_manuscript_outline(plan)
        section_ids = [section["id"] for section in outline]

        self.assertEqual(
            section_ids,
            ["abstract", "keywords", "introduction", "methods", "results", "discussion"],
        )
        self.assertIn("提供数据", outline[2]["text"])
        self.assertNotIn("因果", outline[2]["text"])
        self.assertNotIn("局限性", " ".join(section["title"] for section in outline))
        self.assertNotIn("可复现性", " ".join(section["title"] for section in outline))

    def test_reporting_supplements_are_split_from_manuscript(self) -> None:
        output_dir = self.artifact_dir
        plan = {
            "run": {"random_seed": 20260726},
            "research": {
                "primary_question": "示例研究问题",
                "design": "cross-sectional",
            },
            "analysis": {"modules": ["linear-regression"]},
            "runtime": {"language": "R", "minimum_version": "4.3.0"},
            "data_handling": {"missing_strategy": "module_complete_case"},
        }
        manifest = {"run_id": "contract_test", "analysis_plan_sha256": "abc123"}
        results = {
            "linear-regression": {
                "warnings": ["发现高影响观测，未自动删除。"],
                "limitations": ["观察性关联不能自动解释为因果效应。"],
                "diagnostics": [{"diagnostic": "最大 VIF", "value": 1.2, "status": "pass"}],
            }
        }

        paths = write_reporting_supplements(output_dir, plan, manifest, results)

        self.assertEqual(
            {path.name for path in paths},
            {"06_统计诊断与警告.md", "07_研究局限性.md", "08_可复现性信息.md"},
        )
        diagnostics = (output_dir / "06_统计诊断与警告.md").read_text(encoding="utf-8")
        limitations = (output_dir / "07_研究局限性.md").read_text(encoding="utf-8")
        reproducibility = (output_dir / "08_可复现性信息.md").read_text(encoding="utf-8")
        self.assertIn("最大 VIF", diagnostics)
        self.assertIn("高影响观测", diagnostics)
        self.assertNotIn("观察性关联", diagnostics)
        self.assertIn("观察性关联", limitations)
        self.assertIn("随机种子", reproducibility)

    def test_table_commentary_names_the_evidence_and_does_not_overclaim(self) -> None:
        self.artifact_dir.mkdir(parents=True, exist_ok=True)
        table_path = self.artifact_dir / "group_comparison.csv"
        table_path.write_text(
            "variable,label,n,method,effect_size,effect_size_type,p_adjusted\n"
            "score_followup,随访临床评分,240,Welch ANOVA,0.075,eta squared,0.0002\n",
            encoding="utf-8",
        )
        plan = {
            "variables": {
                "outcomes": {"primary": "score_followup"},
                "labels": {"score_followup": "随访临床评分"},
            }
        }
        result = {
            "tables": [
                {
                    "table_id": "01_连续变量组间比较",
                    "title": "连续变量单因素组间比较",
                    "csv_path": "group_comparison.csv",
                }
            ]
        }

        commentary = build_artifact_commentary(
            self.artifact_dir,
            plan,
            {"group-comparison": result},
            "group-comparison",
            result["tables"][0],
            artifact_number=3,
        )

        self.assertTrue(commentary)
        self.assertIn("如表 3 所示", commentary[0])
        self.assertIn("Welch ANOVA", commentary[0])
        self.assertIn("eta squared", commentary[0])
        self.assertIn("P<0.001", commentary[0])
        self.assertNotIn("表中要点", commentary[0])
        self.assertNotIn("图示解读", commentary[0])
        self.assertNotIn("因果", commentary[0])

    def test_posthoc_commentary_uses_a_single_natural_transition(self) -> None:
        self.artifact_dir.mkdir(parents=True, exist_ok=True)
        table_path = self.artifact_dir / "posthoc.csv"
        table_path.write_text(
            "variable,comparison,estimate,conf_low,conf_high,p_adjusted\n"
            "score_followup,intervention-control,3.64,0.71,6.58,0.010\n",
            encoding="utf-8",
        )
        plan = {
            "variables": {
                "outcomes": {"primary": "score_followup"},
                "labels": {"score_followup": "随访临床评分"},
            }
        }
        result = {
            "tables": [
                {
                    "table_id": "03_事后比较",
                    "title": "连续变量事后比较",
                    "csv_path": "posthoc.csv",
                }
            ]
        }

        commentary = build_artifact_commentary(
            self.artifact_dir,
            plan,
            {"group-comparison": result},
            "group-comparison",
            result["tables"][0],
            artifact_number=5,
        )

        self.assertEqual(len(commentary), 1)
        self.assertTrue(commentary[0].startswith("进一步的事后比较（表 5）显示，"))
        self.assertIn("intervention-control 的均值差为 3.64", commentary[0])
        self.assertNotIn("事后比较进一步", commentary[0])

    def test_article_table_combines_effect_and_ci_with_reader_facing_headers(self) -> None:
        raw_rows = [
            [
                "term",
                "estimate_log_odds",
                "std_error",
                "statistic",
                "p_value",
                "odds_ratio",
                "or_conf_low",
                "or_conf_high",
            ],
            [
                "groupintervention_b",
                "-1.107238478",
                "0.4167238937",
                "-2.657007422",
                "0.007883770741",
                "0.3304703031",
                "0.1460213695",
                "0.7479084847",
            ],
        ]
        plan = {
            "variables": {
                "categorical": ["group"],
                "labels": {"group": "治疗组"},
            }
        }

        rendered = prepare_article_table_rows(raw_rows, plan)

        self.assertEqual(
            rendered[0],
            ["变量（或水平）", "估计值（log odds）", "标准误", "统计量", "P 值", "OR（95% CI）"],
        )
        self.assertEqual(rendered[1][0], "治疗组：intervention_b")
        self.assertEqual(rendered[1][4], "0.008")
        self.assertEqual(rendered[1][5], "0.33（0.15–0.75）")

    def test_regression_table_notes_declared_reference_levels(self) -> None:
        rows = [["term", "estimate"], ["groupintervention_b", "-1.11"]]
        plan = {
            "variables": {
                "categorical": ["group", "sex"],
                "labels": {"group": "治疗组", "sex": "性别"},
                "reference_levels": {"group": "control", "sex": "female"},
            }
        }

        self.assertEqual(
            table_reference_level_note(rows, plan),
            "分类自变量的参照水平：治疗组=control；性别=female。",
        )


if __name__ == "__main__":
    unittest.main()
