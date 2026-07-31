#!/usr/bin/env python3
"""Rebuild the non-circular artifact manifest for one analysis run."""

from __future__ import annotations

import argparse
import hashlib
import json
from datetime import datetime, timezone
from pathlib import Path


def utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def artifact_type(path: Path) -> str:
    suffix = path.suffix.lower()
    if suffix == ".xlsx":
        return "workbook"
    if suffix == ".csv":
        return "table_or_data"
    if suffix == ".docx":
        return "word_report"
    if suffix in {".png", ".svg", ".pdf"}:
        return "figure"
    if suffix == ".rds":
        return "r_object"
    if suffix in {".json", ".yml", ".yaml"}:
        return "metadata"
    if suffix in {".txt", ".log"}:
        return "log"
    return "file"


def module_from_path(relative: Path) -> str:
    text = relative.as_posix()
    if text.startswith("01_数据整理/"):
        return "data-preparation"
    if text.startswith("02_描述性统计/"):
        return "descriptive"
    if text.startswith("03_单因素分析/"):
        return "group-comparison"
    if text.startswith("04_相关性分析/"):
        return "correlation"
    if text.startswith("05_多元线性回归/"):
        return "linear-regression"
    if text.startswith("06_Logistic回归/"):
        return "logistic-regression"
    if text.startswith("07_信度与效度分析/"):
        return "reliability-validity"
    if text.startswith("08_探索性与验证性因子分析/"):
        return "factor-analysis"
    if text.startswith("09_混合效应模型/"):
        return "mixed-effects"
    if text.startswith("10_缺失数据与多重插补/"):
        return "missing-data"
    if text.startswith("20_扩展广义回归/"):
        return "generalized-regression"
    if text.startswith("21_基础生存分析/"):
        return "survival"
    if text.startswith("22_诊断试验准确性/"):
        return "diagnostic-accuracy"
    if text.startswith("23_广义估计方程/"):
        return "gee"
    if text.startswith("24_测量不变性/"):
        return "measurement-invariance"
    if text.startswith("25_竞争风险分析/"):
        return "competing-risks"
    if text.startswith("26_倾向评分分析/"):
        return "propensity-score"
    if text.startswith("27_结构方程模型/"):
        return "sem"
    if text.startswith("30_网络分析/"):
        return "network"
    if text.startswith("31_贝叶斯网络/"):
        return "bayesian"
    if text.startswith("90_最终报告/"):
        return "report"
    if text.startswith("99_运行记录/") or text.startswith("runtime/"):
        return "runtime"
    return "orchestrator"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="更新分析运行 manifest.json。")
    parser.add_argument("--run-dir", required=True)
    parser.add_argument(
        "--phase",
        required=True,
        choices=["inspect", "recommend", "execute", "report"],
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    run_dir = Path(args.run_dir).expanduser().resolve()
    manifest_path = run_dir / "manifest.json"
    previous = {}
    if manifest_path.exists():
        previous = json.loads(manifest_path.read_text(encoding="utf-8"))
    artifacts = []
    excluded_names = {"manifest.json", "validation_report.json"}
    for path in sorted(run_dir.rglob("*")):
        if not path.is_file() or path.name in excluded_names:
            continue
        relative = path.relative_to(run_dir)
        if any(part in {".r-library", "__pycache__", "_qa"} for part in relative.parts):
            continue
        artifacts.append(
            {
                "path": relative.as_posix(),
                "type": artifact_type(path),
                "bytes": path.stat().st_size,
                "sha256": sha256_file(path),
                "created_at_utc": datetime.fromtimestamp(
                    path.stat().st_mtime, timezone.utc
                )
                .replace(microsecond=0)
                .isoformat(),
                "module": module_from_path(relative),
            }
        )
    plan_sha = None
    plan_seed = previous.get("random_seed")
    plan_path = run_dir / "analysis_plan.yml"
    if plan_path.exists():
        try:
            import yaml

            plan = yaml.safe_load(plan_path.read_text(encoding="utf-8-sig"))
            plan_sha = (plan.get("approval") or {}).get("plan_sha256")
            plan_seed = (plan.get("run") or {}).get("random_seed")
        except Exception:
            plan_sha = None
    payload = {
        "schema_version": "1.1",
        "run_id": previous.get("run_id", run_dir.name),
        "phase": args.phase,
        "created_at_utc": previous.get("created_at_utc", utc_now()),
        "updated_at_utc": utc_now(),
        "input_fingerprints": previous.get("input_fingerprints", []),
        "analysis_plan_sha256": plan_sha,
        "random_seed": plan_seed,
        "artifacts": artifacts,
        "warnings": previous.get("warnings", []),
        "validation": previous.get(
            "validation", {"status": "pending", "checked_at_utc": None}
        ),
    }
    manifest_path.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    print(json.dumps({"artifacts": len(artifacts), "phase": args.phase}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
