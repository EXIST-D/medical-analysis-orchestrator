#!/usr/bin/env python3
"""Validate phase outputs, unified results, hashes, and report provenance."""

from __future__ import annotations

import argparse
import hashlib
import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import yaml


REQUIRED = {
    "inspect": [
        "data_inventory.json",
        "data_profile.json",
        "data_profile.csv",
        "01_数据整理/01_变量字典.xlsx",
        "01_数据整理/02_数据质量报告.xlsx",
        "01_数据整理/03_清洗操作候选.csv",
        "manifest.json",
    ],
    "recommend": ["analysis_plan.yml"],
    "execute": [
        "01_数据整理/04_数据清洗日志.csv",
        "01_数据整理/05_清洁分析数据.csv",
        "01_数据整理/06_清洁分析数据.xlsx",
        "runtime/r_environment.json",
        "runtime/python_environment.json",
        "runtime/python_requirements.lock.json",
        "runtime/renv_status.json",
        "runtime/environment_manifest.json",
        "analysis_results.rds",
        "analysis_results.json",
        "execution_status.json",
        "sessionInfo.txt",
        "package_versions.csv",
    ],
    "report": [
        "90_最终报告/01_医学统计分析论文初稿.docx",
        "90_最终报告/05_学术报告表述审计.md",
        "90_最终报告/06_统计诊断与警告.md",
        "90_最终报告/07_研究局限性.md",
        "90_最终报告/08_可复现性信息.md",
    ],
}

ALLOWED_RESULT_STATUS = {
    "completed",
    "completed_with_warnings",
    "skipped",
    "failed",
}
ALLOWED_DIAGNOSTIC_STATUS = {
    "pass", "warning", "fail", "not_assessed", "informational"
}
REQUIRED_FIGURE_STATISTICS = {
    "n_definition",
    "biological_replicates",
    "technical_replicates",
    "center_statistic",
    "interval",
    "test",
    "multiple_comparison_correction",
}
MANUSCRIPT_FIGURE_FORMATS = {"png", "svg", "pdf", "tiff"}


def utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def load_json(path: Path) -> dict[str, Any]:
    payload = json.loads(path.read_text(encoding="utf-8-sig"))
    return payload if isinstance(payload, dict) else {}


def load_plan(path: Path) -> dict[str, Any]:
    payload = yaml.safe_load(path.read_text(encoding="utf-8-sig"))
    return payload if isinstance(payload, dict) else {}


def required_for_mode(mode: str, plan: dict[str, Any] | None = None) -> list[str]:
    order = ["inspect", "recommend", "execute", "report"]
    required: list[str] = []
    for phase in order:
        required.extend(REQUIRED[phase])
        if phase == mode:
            break
    visual = ((plan or {}).get("reporting") or {}).get("visual_regression") or {}
    if mode == "report" and visual.get("enabled", True):
        required.append("90_最终报告/visual_regression/visual_regression.json")
    return required


def selected_module_ids(plan: dict[str, Any]) -> list[str]:
    result = []
    for item in (plan.get("analysis") or {}).get("modules", []):
        if isinstance(item, str):
            result.append(item)
        elif isinstance(item, dict) and item.get("id"):
            result.append(str(item["id"]))
    return result


def reporting_contract(plan: dict[str, Any]) -> dict[str, Any]:
    reporting = plan.get("reporting") or {}
    figure = reporting.get("figure_contract") or {}
    formats = figure.get("formats")
    if not isinstance(formats, list):
        formats = reporting.get("figure_formats") or ["png"]
    return {
        "profile": str(figure.get("profile") or "analysis").lower(),
        "formats": {str(item).lower() for item in formats},
        "require_editable_text": figure.get("require_editable_text") is True,
        "manuscript_enabled": (
            (reporting.get("manuscript_support") or {}).get("enabled") is True
        ),
    }


def registered_evidence_refs(results: dict[str, Any]) -> set[str]:
    references: set[str] = set()
    for module_id, result in results.items():
        for table in result.get("tables", []):
            table_id = table.get("table_id")
            if table_id:
                references.add(f"{module_id}:{table_id}")
        for figure in result.get("figures", []):
            figure_id = figure.get("figure_id")
            if figure_id:
                references.add(f"{module_id}:{figure_id}")
    return references


def resolve_run_artifact(
    run_dir: Path,
    relative: Any,
    *,
    label: str,
    errors: list[str],
) -> Path | None:
    if relative is None or str(relative).strip() == "":
        errors.append(f"{label}缺少路径")
        return None
    run_root = run_dir.resolve()
    candidate = (run_root / str(relative)).resolve()
    try:
        candidate.relative_to(run_root)
    except ValueError:
        errors.append(f"{label}位于运行目录之外：{relative}")
        return None
    return candidate


def validate_result_object(
    module_id: str,
    result: Any,
    run_dir: Path,
    report_contract: dict[str, Any],
) -> list[str]:
    errors: list[str] = []
    if not isinstance(result, dict):
        return [f"{module_id} 结果对象必须是对象"]

    required_result_fields = (
        "schema_version",
        "module_id",
        "method_id",
        "status",
        "started_at_utc",
        "completed_at_utc",
        "sample",
        "tables",
        "figures",
        "model_objects",
        "diagnostics",
        "warnings",
        "limitations",
        "narrative",
        "session_metadata",
    )
    for field in required_result_fields:
        if field not in result:
            errors.append(f"{module_id} 结果对象缺少字段：{field}")

    if result.get("module_id") != module_id:
        errors.append(f"结果对象 module_id 不一致：{module_id}")
    if result.get("status") not in ALLOWED_RESULT_STATUS:
        errors.append(f"结果对象状态非法：{module_id}")
    if result.get("status") == "failed":
        errors.append(f"模块结果失败：{module_id}")

    tables = result.get("tables", [])
    if not isinstance(tables, list):
        errors.append(f"{module_id} tables 必须是列表")
        tables = []
    for table in tables:
        if not isinstance(table, dict):
            errors.append(f"{module_id} 表对象必须是对象")
            continue
        for field in (
            "table_id",
            "title",
            "csv_path",
            "xlsx_path",
            "n_rows",
            "n_columns",
            "columns",
            "footnotes",
            "source_module",
        ):
            if field not in table:
                errors.append(f"{module_id} 表对象缺少字段：{field}")
        if table.get("source_module") not in {None, module_id}:
            errors.append(f"{module_id} 表对象 source_module 不一致")
        for field in ("csv_path", "xlsx_path"):
            relative = table.get(field)
            artifact = resolve_run_artifact(
                run_dir,
                relative,
                label=f"{module_id} 结果表 {field}",
                errors=errors,
            )
            if artifact is not None and not artifact.is_file():
                errors.append(f"{module_id} 结果表不存在：{relative}")

    diagnostics = result.get("diagnostics", [])
    if not isinstance(diagnostics, list):
        errors.append(f"{module_id} diagnostics 必须是列表")
        diagnostics = []
    for diagnostic in diagnostics:
        if not isinstance(diagnostic, dict):
            errors.append(f"{module_id} 诊断对象必须是对象")
            continue
        for field in ("diagnostic", "value", "rule", "status"):
            if field not in diagnostic:
                errors.append(f"{module_id} 诊断对象缺少字段：{field}")
        if diagnostic.get("status") not in ALLOWED_DIAGNOSTIC_STATUS:
            errors.append(
                f"{module_id} 诊断对象 status 非法：{diagnostic.get('status')}"
            )

    figures = result.get("figures", [])
    if not isinstance(figures, list):
        errors.append(f"{module_id} figures 必须是列表")
        figures = []
    for figure in figures:
        if not isinstance(figure, dict):
            errors.append(f"{module_id} 图形对象必须是对象")
            continue
        for field in (
            "figure_id",
            "title",
            "path",
            "preview_path",
            "generated_by",
            "exports",
            "source_data_path",
            "conclusion",
            "evidence_role",
            "statistics",
            "source_module",
        ):
            if field not in figure:
                errors.append(f"{module_id} 图形对象缺少字段：{field}")
        if figure.get("source_module") not in {None, module_id}:
            errors.append(f"{module_id} 图形对象 source_module 不一致")
        if figure.get("generated_by") != "R":
            errors.append(f"{module_id} 图形必须由 R 生成")
        for field, label in (
            ("path", "图形"),
            ("preview_path", "图形预览"),
            ("source_data_path", "图形 Source Data"),
        ):
            relative = figure.get(field)
            artifact = resolve_run_artifact(
                run_dir,
                relative,
                label=f"{module_id} {label}",
                errors=errors,
            )
            if artifact is not None and not artifact.is_file():
                errors.append(f"{module_id} {label}不存在：{relative}")

        statistics = figure.get("statistics")
        if not isinstance(statistics, dict):
            errors.append(f"{module_id} 图形 statistics 必须是对象")
        else:
            missing_statistics = sorted(
                REQUIRED_FIGURE_STATISTICS - set(statistics)
            )
            if missing_statistics:
                errors.append(
                    f"{module_id} 图形统计元数据缺少："
                    + ", ".join(missing_statistics)
                )

        exports = figure.get("exports")
        export_formats: set[str] = set()
        if not isinstance(exports, list) or not exports:
            errors.append(f"{module_id} 图形 exports 不能为空")
        else:
            for export in exports:
                if not isinstance(export, dict):
                    errors.append(f"{module_id} 图形 export 必须是对象")
                    continue
                export_format = str(export.get("format") or "").lower()
                export_path = export.get("path")
                if not export_format or not export_path:
                    errors.append(f"{module_id} 图形 export 缺少 format/path")
                    continue
                export_formats.add(export_format)
                artifact = resolve_run_artifact(
                    run_dir,
                    export_path,
                    label=f"{module_id} 图形导出",
                    errors=errors,
                )
                if artifact is not None and not artifact.is_file():
                    errors.append(f"{module_id} 图形导出不存在：{export_path}")
                if (
                    report_contract["require_editable_text"]
                    and export_format in {"svg", "pdf"}
                    and export.get("editable_text") is not True
                ):
                    errors.append(
                        f"{module_id} {export_format} 未登记可编辑文字"
                    )
        if export_formats != report_contract["formats"]:
            errors.append(f"{module_id} 图形导出格式与确认方案不一致")
        if (
            report_contract["profile"] == "manuscript"
            and not MANUSCRIPT_FIGURE_FORMATS.issubset(export_formats)
        ):
            errors.append(f"{module_id} 投稿图缺少 png/svg/pdf/tiff 导出")

    reporting_evidence = result.get("reporting_evidence")
    if reporting_evidence is not None:
        if not isinstance(reporting_evidence, list):
            errors.append(f"{module_id} reporting_evidence 必须是列表")
        else:
            artifact_ids = {
                str(item.get("table_id"))
                for item in tables
                if isinstance(item, dict) and item.get("table_id")
            } | {
                str(item.get("figure_id"))
                for item in figures
                if isinstance(item, dict) and item.get("figure_id")
            }
            for index, evidence in enumerate(reporting_evidence, start=1):
                label = f"{module_id} reporting_evidence[{index}]"
                if not isinstance(evidence, dict):
                    errors.append(f"{label} 必须是对象")
                    continue
                artifact_id = str(evidence.get("artifact_id") or "")
                statement = evidence.get("result_statement")
                if not artifact_id:
                    errors.append(f"{label} 缺少 artifact_id")
                elif artifact_id not in artifact_ids:
                    errors.append(f"{label} artifact_id 未解析到同一模块图表")
                if not isinstance(statement, str) or not statement.strip():
                    errors.append(f"{label} result_statement 必须是非空字符串")
                interpretation = evidence.get("interpretation")
                if interpretation is not None and not isinstance(interpretation, str):
                    errors.append(f"{label} interpretation 必须是字符串")

    if (
        result.get("status") == "completed_with_warnings"
        and not result.get("warnings")
    ):
        errors.append(f"{module_id} 标记为有警告但 warnings 为空。")
    return errors


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="验证一个医学分析运行目录。")
    parser.add_argument("--run-dir", required=True)
    parser.add_argument(
        "--mode",
        choices=["inspect", "recommend", "execute", "report"],
        required=True,
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    run_dir = Path(args.run_dir).expanduser().resolve()
    errors: list[str] = []
    warnings: list[str] = []
    if not run_dir.is_dir():
        print(json.dumps({"valid": False, "errors": [f"运行目录不存在：{run_dir}"]}, ensure_ascii=False))
        return 2

    plan_path = run_dir / "analysis_plan.yml"
    plan = load_plan(plan_path) if plan_path.exists() else {}

    for relative in required_for_mode(args.mode, plan):
        if not (run_dir / relative).exists():
            errors.append(f"缺少必需输出：{relative}")

    manifest_path = run_dir / "manifest.json"
    manifest = load_json(manifest_path) if manifest_path.exists() else {}
    if manifest:
        if manifest.get("run_id") != run_dir.name:
            warnings.append("manifest.run_id 与目录名不同，请确认是否为有意命名。")
        for artifact in manifest.get("artifacts", []):
            relative = artifact.get("path")
            if not relative:
                errors.append("manifest artifact 缺少 path。")
                continue
            artifact_path = (run_dir / str(relative)).resolve()
            try:
                artifact_path.relative_to(run_dir)
            except ValueError:
                errors.append(f"artifact 路径逃逸运行目录：{relative}")
                continue
            if not artifact_path.is_file():
                errors.append(f"manifest 文件不存在：{relative}")
            elif artifact.get("sha256") and sha256_file(artifact_path) != artifact["sha256"]:
                errors.append(f"artifact SHA-256 不一致：{relative}")

    report_contract = reporting_contract(plan)
    if args.mode == "report" and report_contract["manuscript_enabled"]:
        for relative in (
            "90_最终报告/02_主张证据边界表.csv",
            "90_最终报告/03_统计方法与可复现性.md",
            "90_最终报告/04_术语账本.yml",
            "90_最终报告/05_学术报告表述审计.md",
        ):
            if not (run_dir / relative).is_file():
                errors.append(f"启用 manuscript_support 后缺少输出：{relative}")
    if plan and manifest:
        run_id = (plan.get("run") or {}).get("run_id")
        if run_id and run_id != manifest.get("run_id"):
            errors.append("analysis_plan.yml 与 manifest.json 的 run_id 不一致。")
        plan_sha = (plan.get("approval") or {}).get("plan_sha256")
        if args.mode in {"execute", "report"} and plan_sha != manifest.get("analysis_plan_sha256"):
            errors.append("manifest 中的分析方案指纹不一致。")

    if args.mode in {"execute", "report"}:
        status_path = run_dir / "execution_status.json"
        if status_path.exists():
            status = load_json(status_path)
            if status.get("status") != "completed":
                errors.append(f"执行状态不是 completed：{status.get('status')}")
            expected_modules = selected_module_ids(plan)
            completed_modules = status.get("completed_modules", [])
            if isinstance(completed_modules, str):
                completed_modules = [completed_modules]
            if completed_modules != expected_modules:
                errors.append("execution_status 中的完成模块与确认方案不一致。")

        results_path = run_dir / "analysis_results.json"
        if results_path.exists():
            results = load_json(results_path)
            expected_modules = selected_module_ids(plan)
            if list(results.keys()) != expected_modules:
                errors.append("统一结果对象的模块顺序或集合与确认方案不一致。")
            for module_id, result in results.items():
                errors.extend(
                    validate_result_object(
                        module_id,
                        result,
                        run_dir,
                        report_contract,
                    )
                )
            if report_contract["manuscript_enabled"]:
                available_refs = registered_evidence_refs(results)
                claims = (
                    ((plan.get("reporting") or {}).get("manuscript_support") or {})
                    .get("claims")
                    or []
                )
                for claim in claims:
                    for evidence_ref in claim.get("evidence_refs") or []:
                        if str(evidence_ref) not in available_refs:
                            errors.append(
                                "论文主张引用未注册的证据对象："
                                + str(evidence_ref)
                            )

    report = {
        "schema_version": "1.1",
        "checked_at_utc": utc_now(),
        "run_dir": str(run_dir),
        "mode": args.mode,
        "valid": not errors,
        "errors": errors,
        "warnings": warnings,
    }
    report_path = run_dir / "validation_report.json"
    report_path.write_text(
        json.dumps(report, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    if manifest:
        manifest["validation"] = {
            "status": "passed" if not errors else "failed",
            "checked_at_utc": report["checked_at_utc"],
            "report": report_path.name,
        }
        manifest_path.write_text(
            json.dumps(manifest, ensure_ascii=False, indent=2),
            encoding="utf-8",
        )
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0 if not errors else 2


if __name__ == "__main__":
    raise SystemExit(main())
