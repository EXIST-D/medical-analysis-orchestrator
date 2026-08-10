#!/usr/bin/env python3
"""Audit existing R-produced figure artifacts; never calculate or redraw plots."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


REQUIRED_STATS = {
    "n_definition",
    "biological_replicates",
    "technical_replicates",
    "center_statistic",
    "interval",
    "test",
    "multiple_comparison_correction",
}


def safe_path(run_dir: Path, value: Any) -> Path | None:
    if not isinstance(value, str) or not value.strip():
        return None
    candidate = (run_dir / value).resolve() if not Path(value).is_absolute() else Path(value).resolve()
    try:
        candidate.relative_to(run_dir.resolve())
    except ValueError:
        return None
    return candidate


def image_info(path: Path) -> tuple[dict[str, Any], str | None]:
    try:
        from PIL import Image
    except ImportError:
        return {"available": False}, "Pillow 未安装，未能读取图像像素信息。"
    try:
        with Image.open(path) as image:
            info = {
                "available": True,
                "format": image.format,
                "width_px": image.width,
                "height_px": image.height,
                "mode": image.mode,
                "dpi": image.info.get("dpi"),
            }
        return info, None
    except Exception as exc:  # pragma: no cover - depends on external image codecs
        return {"available": False}, f"无法读取图像 {path.name}: {exc}"


def write_grayscale_preview(source: Path, target: Path) -> str | None:
    try:
        from PIL import Image
    except ImportError:
        return "Pillow 未安装，跳过灰度预览。"
    try:
        with Image.open(source) as image:
            converted = image.convert("L")
            target.parent.mkdir(parents=True, exist_ok=True)
            converted.save(target, format="PNG")
        return None
    except Exception as exc:  # pragma: no cover
        return f"灰度预览生成失败：{exc}"


def audit(run_dir: Path, result_path: Path, output: Path, grayscale: bool, min_dpi: int) -> dict[str, Any]:
    payload = json.loads(result_path.read_text(encoding="utf-8"))
    errors: list[str] = []
    warnings: list[str] = []
    figures: list[dict[str, Any]] = []
    for module_id, result in payload.items():
        for figure in (result or {}).get("figures", []) if isinstance(result, dict) else []:
            label = f"{module_id}:{figure.get('figure_id', 'unknown')}"
            row: dict[str, Any] = {"id": label, "module": module_id, "figure_id": figure.get("figure_id")}
            if figure.get("generated_by") != "R":
                errors.append(f"{label} 不是 R 生成")
            stats = figure.get("statistics")
            if not isinstance(stats, dict) or REQUIRED_STATS - set(stats):
                errors.append(f"{label} 缺少完整统计元数据")
            if not str(figure.get("conclusion") or "").strip():
                errors.append(f"{label} 缺少图形结论")
            if not str(figure.get("evidence_role") or "").strip():
                errors.append(f"{label} 缺少证据角色")
            preview = safe_path(run_dir, figure.get("preview_path"))
            if preview is None or not preview.is_file():
                errors.append(f"{label} 预览文件不存在或越界")
            else:
                info, warning = image_info(preview)
                row["preview"] = info
                if warning:
                    warnings.append(f"{label}: {warning}")
                elif info.get("width_px", 0) < 600 or info.get("height_px", 0) < 400:
                    warnings.append(f"{label} PNG 像素尺寸偏小：{info.get('width_px')}×{info.get('height_px')}")
                dpi = info.get("dpi")
                if dpi and min(dpi) < min_dpi - 1:
                    warnings.append(f"{label} PNG 实际 DPI 低于配置下限 {min_dpi}：{dpi}")
                elif not dpi:
                    warnings.append(f"{label} PNG 未登记可读取 DPI。")
                if grayscale:
                    target = run_dir / "90_最终报告" / "visual_regression" / "figures_grayscale" / f"{figure.get('figure_id', 'figure')}.png"
                    warning = write_grayscale_preview(preview, target)
                    if warning:
                        warnings.append(f"{label}: {warning}")
                    else:
                        row["grayscale_preview_path"] = str(target.relative_to(run_dir))
            export_rows = []
            for export in figure.get("exports", []) if isinstance(figure.get("exports"), list) else []:
                export_path = safe_path(run_dir, export.get("path"))
                export_rows.append({"format": export.get("format"), "exists": bool(export_path and export_path.is_file())})
                if export_path is None or not export_path.is_file():
                    errors.append(f"{label} 导出文件不存在或越界：{export.get('path')}")
            row["exports"] = export_rows
            figures.append(row)
    status = "fail" if errors else ("warning" if warnings else "pass")
    report = {
        "schema_version": "figure-visual-qa-1.0",
        "status": status,
        "run_dir": str(run_dir),
        "result_source": str(result_path),
        "engine_boundary": "R 生成；Python 仅检查和生成现有 PNG 的灰度审阅副本",
        "errors": errors,
        "warnings": warnings,
        "figures": figures,
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description="校验 R 图形产物并生成视觉 QA 记录。")
    parser.add_argument("--run-dir", required=True, type=Path)
    parser.add_argument("--results", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--grayscale", action="store_true")
    parser.add_argument("--min-dpi", type=int, default=300)
    args = parser.parse_args()
    run_dir = args.run_dir.resolve()
    results = (args.results or run_dir / "analysis_results.json").resolve()
    output = (args.output or run_dir / "90_最终报告" / "figure_visual_qa.json").resolve()
    if not results.is_file():
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps({"status": "not_applicable", "errors": ["analysis_results.json 不存在"], "warnings": [], "figures": []}, ensure_ascii=False, indent=2), encoding="utf-8")
        return 0
    report = audit(run_dir, results, output, args.grayscale, args.min_dpi)
    print(json.dumps({"status": report["status"], "figures": len(report["figures"]), "output": str(output)}, ensure_ascii=False))
    return 1 if report["status"] == "fail" else 0


if __name__ == "__main__":
    raise SystemExit(main())
