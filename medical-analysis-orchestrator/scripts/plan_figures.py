#!/usr/bin/env python3
"""Create an auditable, data-aware figure plan without drawing figures."""

from __future__ import annotations

import argparse
import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import yaml


MODULE_ROLES: dict[str, dict[str, Any]] = {
    "descriptive": {"role": "distribution", "default": "grouped_distribution_and_summary"},
    "group-comparison": {"role": "comparison", "default": "raw_points_with_effect_interval"},
    "correlation": {"role": "association", "default": "correlation_heatmap_with_n_matrix"},
    "linear-regression": {"role": "model_diagnostics", "default": "diagnostic_residual_panels"},
    "logistic-regression": {"role": "prediction", "default": "roc_and_calibration"},
    "reliability-validity": {"role": "measurement", "default": "item_contribution_and_scale_evidence"},
    "factor-analysis": {"role": "measurement", "default": "factor_structure_and_loadings"},
    "mixed-effects": {"role": "longitudinal", "default": "individual_trajectories_and_population_fit"},
    "missing-data": {"role": "data_quality", "default": "missingness_profile_and_pattern"},
    "generalized-regression": {"role": "effect_estimate", "default": "estimand_specific_forest"},
    "survival": {"role": "time_to_event", "default": "km_with_risk_table"},
    "diagnostic-accuracy": {"role": "diagnostic", "default": "roc_threshold_performance"},
    "gee": {"role": "longitudinal", "default": "population_average_prediction"},
    "measurement-invariance": {"role": "measurement", "default": "fit_change_across_constraints"},
    "competing-risks": {"role": "time_to_event", "default": "cumulative_incidence"},
    "propensity-score": {"role": "causal_association", "default": "overlap_and_balance"},
    "sem": {"role": "structural_model", "default": "path_estimates_with_uncertainty"},
    "network": {"role": "exploratory_association", "default": "network_with_stability_boundary"},
    "bayesian": {"role": "exploratory_association", "default": "conditional_dependence_structure"},
}


DEFAULT_RULES = [
    "mean_only_bar_for_small_n",
    "dual_y_axis",
    "pie_chart",
    "three_dimensional_chart",
    "rainbow_palette",
    "unapproved_significance_stars",
    "line_joining_unordered_categories",
]


def load_yaml(path: Path) -> dict[str, Any]:
    payload = yaml.safe_load(path.read_text(encoding="utf-8-sig"))
    return payload if isinstance(payload, dict) else {}


def build_plan(config: dict[str, Any], profile: dict[str, Any] | None) -> dict[str, Any]:
    analysis = config.get("analysis") or {}
    reporting = config.get("reporting") or {}
    figure_contract = reporting.get("figure_contract") or {}
    figure_plan = reporting.get("figure_plan") or {}
    modules = [str(item) for item in analysis.get("modules", [])]
    module_entries = []
    overrides = figure_plan.get("module_overrides") or {}
    for module_id in modules:
        registry = MODULE_ROLES.get(module_id, {"role": "module_specific", "default": "module_defined"})
        override = overrides.get(module_id) if isinstance(overrides, dict) else None
        entry = {
            "module": module_id,
            "figure_plan_id": f"{module_id}:default",
            "evidence_role": str((override or {}).get("evidence_role", registry["role"])),
            "recommended_figure": str((override or {}).get("figure", registry["default"])),
            "selection_reason": str((override or {}).get("reason", "由模块的估计目标、变量结构和医学证据角色决定。")),
            "required_metadata": ["n_definition", "center_statistic", "interval", "test", "multiple_comparison_correction"],
            "status": "recommended",
        }
        module_entries.append(entry)

    source_summary = (profile.get("summary") or {}) if isinstance(profile, dict) else {}
    profile_summary = {
        "available": isinstance(profile, dict),
        "n_rows": source_summary.get("total_rows_across_datasets", profile.get("n_rows") if isinstance(profile, dict) else None),
        "n_columns": source_summary.get("total_variables_across_datasets", profile.get("n_columns") if isinstance(profile, dict) else None),
        "overall_missing_pct": source_summary.get("overall_missing_pct"),
        "candidate_role_counts": source_summary.get("candidate_role_counts", {}),
        "missingness_checked": isinstance(profile, dict),
    }
    return {
        "schema_version": "figure-plan-1.0",
        "generated_at_utc": datetime.now(timezone.utc).isoformat(),
        "selection_mode": str(figure_plan.get("selection_mode", "auto_recommend_then_confirm")),
        "require_confirmation": bool(figure_plan.get("require_confirmation", False)),
        "journal_profile": str(figure_plan.get("journal_profile", figure_contract.get("journal_profile", "medical-academic-v1"))),
        "template": str(figure_contract.get("template", "medical-academic-v1")),
        "profile": str(figure_contract.get("profile", "analysis")),
        "data_profile": profile_summary,
        "guardrails": list(figure_plan.get("prohibited", DEFAULT_RULES)),
        "modules": module_entries,
        "notes": [
            "此文件只记录图形选择与质控计划，不替代 R 的统计计算。",
            "图形结论必须来自同一 run_id 的统一结果对象和 Source Data。",
        ],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="生成可审计的医学科研绘图方案。")
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--profile", type=Path)
    args = parser.parse_args()
    config = load_yaml(args.config.resolve())
    profile = None
    if args.profile and args.profile.exists():
        profile = json.loads(args.profile.read_text(encoding="utf-8"))
    plan = build_plan(config, profile)
    args.output.resolve().parent.mkdir(parents=True, exist_ok=True)
    args.output.resolve().write_text(json.dumps(plan, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps({"status": "created", "output": str(args.output.resolve()), "figures": len(plan["modules"])}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
