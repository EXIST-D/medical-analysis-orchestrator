#!/usr/bin/env python3
"""Generate a conservative, unconfirmed analysis plan from an aggregate profile."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

try:
    import yaml
except ImportError:
    yaml = None


def utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def collect_candidates(profile: dict[str, Any]) -> dict[str, list[dict[str, Any]]]:
    result: dict[str, list[dict[str, Any]]] = {
        "id": [],
        "outcome": [],
        "group": [],
        "time": [],
        "event": [],
        "scale_item": [],
        "binary": [],
        "continuous": [],
        "categorical": [],
    }
    for dataset in profile.get("datasets", []):
        source = dataset.get("source")
        for variable in dataset.get("variables", []):
            item = {
                "source": source,
                "name": variable.get("name"),
                "inferred_type": variable.get("inferred_type"),
                "missing_pct": variable.get("missing_pct"),
                "unique_n": variable.get("unique_n"),
            }
            for role in variable.get("candidate_roles", []):
                normalized_role = "id" if role == "possible_id" else role
                if normalized_role in result:
                    result[normalized_role].append(item)
            inferred_type = variable.get("inferred_type")
            if inferred_type == "binary":
                result["binary"].append(item)
            elif inferred_type == "continuous":
                result["continuous"].append(item)
            elif inferred_type in {"categorical", "categorical_numeric"}:
                result["categorical"].append(item)
    return result


def method(
    module: str,
    name: str,
    rationale: str,
    conditions: list[str],
    limitations: list[str],
    priority: str = "candidate",
) -> dict[str, Any]:
    return {
        "module": module,
        "method": name,
        "priority": priority,
        "rationale": rationale,
        "conditions": conditions,
        "limitations": limitations,
        "confirmed": False,
    }


def build_recommendations(
    profile: dict[str, Any],
    candidates: dict[str, list[dict[str, Any]]],
    research_question: str,
) -> list[dict[str, Any]]:
    recommendations = [
        method(
            "inspect",
            "data-quality-review",
            "所有正式医学分析都需要先确认缺失、重复、编码和逻辑一致性。",
            ["确认特殊缺失编码", "确认纳入排除规则", "确认原始数据保持只读"],
            ["统计异常不等同于数据错误"],
            "primary",
        ),
        method(
            "descriptive",
            "descriptive-statistics",
            "先描述样本、变量分布和分析样本形成过程。",
            ["按变量尺度选择汇总指标", "对小单元格执行隐私抑制"],
            ["描述性统计不能控制混杂或证明因果"],
            "primary",
        ),
    ]

    if float((profile.get("summary") or {}).get("overall_missing_pct") or 0) > 0:
        recommendations.append(
            method(
                "missing-data",
                "missingness-audit",
                "数据中存在缺失值，应先审计缺失模式并由研究者确认处理策略。",
                [
                    "确认结构性缺失、特殊缺失编码和分析变量",
                    "若采用多重插补，确认插补模型、次数和下游 Rubin 规则合并",
                ],
                ["观测数据不能自动证明 MCAR、MAR 或 MNAR", "不得用单个插补数据集冒充多重插补推断"],
                "primary",
            )
        )

    if candidates["group"]:
        recommendations.append(
            method(
                "group-comparison",
                "group-comparison",
                "检测到候选分组变量，可在确认独立/配对结构后比较组间差异。",
                [
                    "确认分组变量及参照组",
                    "检查连续变量分布和方差",
                    "检查列联表期望频数",
                    "预先定义多重比较族",
                ],
                [
                    "未经调整的组间比较可能受混杂影响",
                    "不能只根据正态性检验自动选择方法",
                ],
            )
        )

    outcome_types = {
        item["inferred_type"] for item in candidates["outcome"] if item["inferred_type"]
    }
    if "binary" in outcome_types:
        recommendations.append(
            method(
                "logistic-regression",
                "logistic-regression",
                "候选结局变量中包含二分类变量。",
                [
                    "用户确认主要结局、事件编码和参照组",
                    "检查事件数、参数数、完全分离和函数形式",
                    "明确混杂变量选择依据",
                ],
                [
                    "优势比在常见结局中不等同于风险比",
                    "观察性关联不自动具有因果解释",
                ],
            )
        )
    if "continuous" in outcome_types:
        recommendations.append(
            method(
                "linear-regression",
                "linear-regression",
                "候选结局变量中包含连续变量。",
                [
                    "用户确认主要结局和函数形式",
                    "检查残差、异方差、影响点和共线性",
                ],
                ["严重偏态或有界结局可能需要变换、稳健方法或其他分布族"],
            )
        )
    if len(candidates["continuous"]) >= 2:
        recommendations.append(
            method(
                "correlation",
                "correlation-analysis",
                "检测到至少两个连续变量，可在研究问题需要时评估线性或秩相关。",
                [
                    "确认纳入相关矩阵的变量",
                    "确认 Pearson、Spearman 或 Kendall 方法",
                    "确认多重检验校正范围",
                ],
                ["相关关系不等于因果关系", "成对完整案例可能使用不同样本"],
            )
        )
    if outcome_types.intersection({"categorical", "categorical_numeric"}):
        recommendations.append(
            method(
                "generalized-regression",
                "categorical-outcome-regression",
                "候选结局变量中包含分类或有序变量。",
                [
                    "确认类别是否有序及参照组",
                    "有序模型检查比例优势假设",
                    "检查稀疏类别和参数数量",
                ],
                ["有序与无序分类需要不同模型，不能仅凭编码值判断"],
            )
        )

    if candidates["time"] and candidates["event"]:
        recommendations.append(
            method(
                "survival",
                "survival-analysis",
                "同时检测到候选时间和事件变量，可评估随访至事件结局。",
                [
                    "确认时间起点、时间尺度、事件编码和删失规则",
                    "检查比例风险和竞争风险",
                ],
                ["名称匹配不能证明变量构成有效的生存结局"],
            )
        )

    if candidates["id"] and candidates["time"]:
        recommendations.append(
            method(
                "mixed-effects",
                "mixed-effects-model",
                "检测到候选受试者 ID 与时间/访视变量，可能存在重复测量结构。",
                [
                    "确认一名受试者对应多行观测",
                    "确认结局分布、相关结构和失访机制",
                ],
                ["混合模型与 GEE 回答的效应层级不同"],
            )
        )
        recommendations.append(
            method(
                "gee",
                "population-average-longitudinal-model",
                "检测到候选受试者 ID 与时间/访视变量，可在研究目标为群体平均效应时考虑 GEE。",
                [
                    "确认结局分布、聚类 ID、时间顺序和工作相关结构",
                    "确认研究问题需要群体平均效应而非个体特异效应",
                ],
                ["聚类数过少时稳健标准误可能不可靠", "GEE 与混合模型的效应解释不同"],
            )
        )

    if len(candidates["scale_item"]) >= 3:
        recommendations.append(
            method(
                "reliability-validity",
                "reliability-validity-analysis",
                "检测到多个候选量表条目，可先评估预先定义量表的内部一致性和因子分析适用性。",
                [
                    "提供量表手册或确认条目、反向计分和理论维度",
                    "确认效标变量及效度证据类型",
                ],
                ["不能仅凭相似列名自动构造总分、反向计分或维度"],
            )
        )
        recommendations.append(
            method(
                "factor-analysis",
                "efa-or-cfa",
                "检测到多个候选量表条目，可在理论与样本量支持时考虑 EFA 或 CFA。",
                [
                    "EFA 因子数必须由确认方案给出，并结合平行分析解释",
                    "CFA 必须提供明确的 lavaan 模型语法、估计量和缺失策略",
                ],
                ["EFA 与 CFA 不应在缺乏验证设计的同一数据上反复试配后宣称结构已确认"],
            )
        )

    normalized_question = research_question.lower()
    if re.search(r"诊断|roc|auc|敏感度|灵敏度|特异度|diagnostic", normalized_question):
        recommendations.append(
            method(
                "diagnostic-accuracy",
                "diagnostic-accuracy",
                "研究问题涉及诊断标志物、ROC、AUC 或阈值性能。",
                ["确认金标准、阳性事件、标志物方向和预先指定阈值", "区分数据驱动阈值与外部验证阈值"],
                ["PPV/NPV 依赖患病率", "同一样本选阈值并评估会产生乐观偏倚"],
            )
        )
    if re.search(r"竞争风险|competing risk|fine.?gray|累积发生", normalized_question):
        recommendations.append(
            method(
                "competing-risks",
                "competing-risk-analysis",
                "研究问题涉及目标事件与竞争事件。",
                ["确认删失、目标事件和所有竞争事件编码", "确认需要累积发生函数、原因别风险还是亚分布风险"],
                ["Fine–Gray 亚分布风险比不能与原因别 HR 混用"],
            )
        )
    if re.search(r"倾向评分|propensity|iptw|overlap weight|因果效应", normalized_question):
        recommendations.append(
            method(
                "propensity-score",
                "propensity-score-weighting",
                "研究问题明确涉及观察性处理效应或倾向评分。",
                ["确认处理时间、基线混杂变量、estimand 与权重类型", "审查共同支持、极端权重和加权后平衡"],
                ["只能平衡已测量混杂", "因果解释需要额外识别假设"],
            )
        )
    if re.search(r"结构方程|sem|路径分析|中介效应|间接效应", normalized_question):
        recommendations.append(
            method(
                "sem",
                "structural-equation-model",
                "研究问题涉及结构方程、路径或间接效应。",
                ["提供理论驱动的 lavaan 模型语法", "确认估计量、时间顺序、间接效应和验证策略"],
                ["整体拟合良好不能证明因果方向或模型唯一"],
            )
        )
    if re.search(r"网络|network|bridge|桥接", normalized_question):
        recommendations.append(
            method(
                "network",
                "network-analysis",
                "研究问题明确涉及节点关系、网络稳定性或桥接指标。",
                [
                    "确认节点定义、估计方法、正则化和 Bootstrap 次数",
                    "检查样本量与网络稳定性",
                ],
                ["横断面网络边和箭头不构成确定因果证据"],
            )
        )
    if re.search(r"贝叶斯网络|bayesian network|dag|条件依赖", normalized_question):
        recommendations.append(
            method(
                "bayesian",
                "bayesian-network",
                "研究问题明确涉及贝叶斯网络或条件依赖结构。",
                [
                    "确认节点、黑白名单、先验约束和结构学习策略",
                    "通过 Bootstrap 评估边与方向稳定性",
                ],
                ["观察数据中的边方向通常不能单独确立因果关系"],
            )
        )
    return recommendations


def dump_yaml_or_json(path: Path, payload: dict[str, Any]) -> None:
    if yaml is not None:
        text = yaml.safe_dump(
            payload,
            allow_unicode=True,
            sort_keys=False,
            default_flow_style=False,
        )
    else:
        # JSON is valid YAML 1.2 and preserves a machine-readable fallback.
        text = json.dumps(payload, ensure_ascii=False, indent=2)
    path.write_text(text, encoding="utf-8")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Recommend, but do not execute, medical analysis methods."
    )
    parser.add_argument("--profile", required=True, help="data_profile.json")
    parser.add_argument("--output", required=True, help="analysis_plan.yml")
    parser.add_argument("--research-question", default="", help="Research question")
    parser.add_argument("--design", default="unknown", help="Known research design")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    profile_path = Path(args.profile).expanduser().resolve()
    output_path = Path(args.output).expanduser().resolve()
    profile = json.loads(profile_path.read_text(encoding="utf-8"))
    candidates = collect_candidates(profile)
    recommendations = build_recommendations(
        profile, candidates, args.research_question
    )

    decisions_required = [
        "确认主要研究问题与研究设计",
        "确认主要结局变量及其临床含义",
        "确认暴露/自变量、协变量、分组与参照组",
        "确认缺失值、异常值、排除和多重比较策略",
    ]
    if candidates["time"] or candidates["event"]:
        decisions_required.append("确认时间起点、事件编码和删失定义")
    if candidates["scale_item"]:
        decisions_required.append("提供或确认量表计分规则")

    input_value = profile.get("input_path", "")
    input_file = Path(input_value) if input_value else None
    expected_sha256 = (
        sha256_file(input_file)
        if input_file is not None and input_file.is_file()
        else None
    )
    plan = {
        "schema_version": "1.1",
        "generated_at_utc": utc_now(),
        "status": "proposed",
        "run": {
            "run_id": output_path.parent.name,
            "mode": "confirm",
            "output_dir": str(output_path.parent),
            "random_seed": 20260726,
        },
        "input": {
            "path": input_value,
            "dataset": "",
            "sheet": None,
            "format": "auto",
            "encoding": "auto",
            "read_only": True,
            "expected_sha256": expected_sha256,
            "profile_sha256": sha256_file(profile_path),
            "prepared_data_path": "01_数据整理/05_清洁分析数据.csv",
        },
        "research": {
            "primary_question": args.research_question,
            "design": args.design,
            "primary_objective": "",
            "estimand_or_target": "",
        },
        "candidate_variables": {
            key: value
            for key, value in candidates.items()
            if key in {"id", "outcome", "group", "time", "event", "scale_item"}
        },
        "variables": {
            "id": None,
            "outcomes": {"primary": None, "secondary": []},
            "exposures": [],
            "covariates": [],
            "categorical": [],
            "grouping": [],
            "time": None,
            "event": None,
            "reference_levels": {},
            "labels": {},
            "units": {},
        },
        "data_handling": {
            "auto_actions": [
                "copy_to_run",
                "normalize_column_names",
                "disambiguate_duplicate_column_names",
                "write_utf8_csv",
            ],
            "confirmed_actions": [],
            "missing_value_codes": [],
            "missing_strategy": "undecided",
            "duplicate_strategy": "report_only",
            "outlier_strategy": "report_only",
            "exclusions": [],
            "transformations": [],
            "recodes": [],
            "merge_plan": [],
            "multiple_testing": {
                "method": "undecided",
                "family_definition": "",
            },
        },
        "recommendations": recommendations,
        "analysis": {
            "modules": [],
            "methods": [],
            "parameters": {
                "descriptive": {
                    "continuous": [],
                    "categorical": [],
                    "stratify_by": None,
                },
                "group-comparison": {
                    "group": None,
                    "continuous": [],
                    "categorical": [],
                    "paired": False,
                    "continuous_method": "auto",
                    "posthoc": "none",
                },
                "correlation": {
                    "variables": [],
                    "method": "spearman",
                    "adjust_method": "holm",
                },
                "linear-regression": {
                    "outcome": None,
                    "predictors": [],
                    "categorical": [],
                    "robust_se": False,
                },
                "logistic-regression": {
                    "outcome": None,
                    "event_level": None,
                    "predictors": [],
                    "categorical": [],
                    "reference_levels": {},
                },
                "reliability-validity": {
                    "scales": {},
                    "compute_omega": True,
                    "criterion_variables": [],
                    "criterion_method": "spearman",
                    "minimum_complete_n": 30,
                },
                "factor-analysis": {
                    "items": [],
                    "efa": {
                        "enabled": False,
                        "factors": None,
                        "extraction": "minres",
                        "rotation": "oblimin",
                        "parallel_analysis": True,
                        "parallel_iterations": 50,
                        "loading_cutoff": 0.30,
                    },
                    "cfa": {
                        "enabled": False,
                        "model": "",
                        "estimator": "MLR",
                        "ordered": [],
                        "missing": "fiml",
                        "std_lv": True,
                        "modification_index_threshold": 10,
                    },
                },
                "mixed-effects": {
                    "family": "gaussian",
                    "outcome": None,
                    "event_level": None,
                    "fixed_effects": [],
                    "interactions": [],
                    "categorical": [],
                    "reference_levels": {},
                    "group": None,
                    "random_intercept": True,
                    "random_slopes": [],
                    "correlated_random_effects": True,
                    "time_variable": None,
                    "reml": True,
                    "optimizer": "bobyqa",
                },
                "missing-data": {
                    "variables": [], "method": "audit", "imputations": 5,
                    "iterations": 10, "minimum_complete_n": 20,
                },
                "generalized-regression": {
                    "family": "ordinal", "outcome": None, "predictors": [],
                    "categorical": [], "reference_levels": {},
                    "outcome_reference": None, "offset": None,
                    "confidence_level": 0.95,
                },
                "survival": {
                    "time": None, "event": None, "event_level": None,
                    "group": None, "predictors": [], "categorical": [],
                    "reference_levels": {}, "confidence_level": 0.95,
                },
                "diagnostic-accuracy": {
                    "outcome": None, "event_level": None, "markers": [],
                    "thresholds": {}, "direction": "auto", "confidence_level": 0.95,
                },
                "gee": {
                    "family": "gaussian", "outcome": None, "event_level": None,
                    "id": None, "time": None, "predictors": [], "categorical": [],
                    "reference_levels": {}, "correlation_structure": "exchangeable",
                    "confidence_level": 0.95,
                },
                "measurement-invariance": {
                    "items": [], "group": None, "model": "", "ordered": [],
                    "estimator": "MLR", "missing": "fiml",
                    "levels": ["configural", "metric", "scalar", "strict"],
                },
                "competing-risks": {
                    "time": None, "status": None, "event_code": None,
                    "censor_code": "0", "group": None, "covariates": [],
                    "categorical": [], "confidence_level": 0.95,
                },
                "propensity-score": {
                    "treatment": None, "treated_level": None, "covariates": [],
                    "categorical": [], "weight_type": "overlap", "estimand": "ATO",
                    "outcome": None, "outcome_type": "continuous", "event_level": None,
                    "confidence_level": 0.95,
                },
                "sem": {
                    "model": "", "estimator": "MLR", "ordered": [],
                    "missing": "fiml", "std_lv": True, "bootstrap_iterations": 0,
                },
                "network": {
                    "nodes": [], "correlation": "spearman", "tuning": 0.5,
                    "bootstrap_iterations": 100, "communities": {},
                },
                "bayesian": {
                    "nodes": [], "algorithm": "hc", "bootstrap_iterations": 100,
                    "strength_threshold": 0.85, "whitelist": [], "blacklist": [],
                },
            },
            "diagnostics": [],
            "sensitivity_analyses": [],
        },
        "runtime": {
            "language": "R",
            "r_executable": "auto",
            "minimum_version": "4.3.0",
            "auto_install_missing_packages": True,
            "library_scope": "project",
            "project_library": ".r-library",
            "repository": "https://cloud.r-project.org",
            "use_renv": "auto",
            "project_dir": "",
        },
        "reporting": {
            "language": "zh-CN",
            "table_formats": ["csv", "xlsx"],
            "figure_contract": {
                "profile": "analysis",
                "backend": "R",
                "formats": ["png"],
                "width_mm": 183,
                "height_mm": 120,
                "dpi": 300,
                "require_source_data": True,
                "require_statistics_metadata": True,
                "require_editable_text": False,
            },
            "manuscript_support": {
                "enabled": False,
                "separate_results_and_interpretation": True,
                "include_methods_reproducibility": True,
                "build_terminology_ledger": True,
                "claims": [],
                "terminology": {},
            },
            "build_word_report": True,
            "suppress_small_cells": True,
            "small_cell_threshold": 5,
            "include_patient_level_data": False,
            "word": {
                "east_asia_font": "宋体",
                "latin_font": "Times New Roman",
                "body_size_pt": 12,
                "line_spacing": 1.5,
                "first_line_indent_chars": 2,
            },
            "workbook": {
                "east_asia_font": "宋体",
                "latin_font": "Times New Roman",
                "body_size_pt": 10.5,
                "style": "three_line",
                "use_color": False,
            },
        },
        "decisions_required": decisions_required,
        "approval": {
            "confirmed": False,
            "confirmed_by": "",
            "confirmed_at": "",
            "plan_sha256": "",
            "notes": "",
        },
        "limitations": [
            "变量角色仅依据列名和聚合结构标记为候选，尚未由研究者确认。",
            "当前方案未执行任何推断模型。",
            "方法建议不能替代研究方案、数据字典和临床判断。",
        ],
    }
    output_path.parent.mkdir(parents=True, exist_ok=True)
    dump_yaml_or_json(output_path, plan)

    manifest_path = output_path.parent / "manifest.json"
    if manifest_path.exists():
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        manifest["phase"] = "recommend"
        manifest["artifacts"] = [
            item
            for item in manifest.get("artifacts", [])
            if item.get("path") != output_path.name
        ]
        manifest["artifacts"].append(
            {
                "path": output_path.name,
                "type": "analysis_plan",
                "bytes": output_path.stat().st_size,
                "sha256": sha256_file(output_path),
                "created_at_utc": utc_now(),
                "module": "recommend",
            }
        )
        manifest_path.write_text(
            json.dumps(manifest, ensure_ascii=False, indent=2),
            encoding="utf-8",
        )

    print(
        json.dumps(
            {
                "status": "proposed",
                "recommendation_count": len(recommendations),
                "decisions_required": decisions_required,
                "execution_started": False,
                "output": str(output_path),
            },
            ensure_ascii=False,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
