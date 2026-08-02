#!/usr/bin/env python3
"""Generate anonymous data and execute every registered R module for real."""

from __future__ import annotations

import argparse
import csv
import json
import math
import os
import random
import shutil
import subprocess
import sys
from pathlib import Path

import yaml


REPO_ROOT = Path(__file__).resolve().parents[1]
SKILL_ROOT = REPO_ROOT / "medical-analysis-orchestrator"
MATRIX_PATH = Path(__file__).with_name("module_execution_matrix.yml")
R_RUNNER = Path(__file__).with_name("run_single_module.R")
DEFAULT_WORK_DIR = Path(__file__).with_name("_matrix_runs")


def logistic(value: float) -> float:
    return 1.0 / (1.0 + math.exp(-value))


def poisson_sample(rng: random.Random, rate: float) -> int:
    threshold = math.exp(-rate)
    product = 1.0
    count = 0
    while product > threshold:
        count += 1
        product *= rng.random()
    return count - 1


def generate_dataset(path: Path) -> None:
    rng = random.Random(20260803)
    fields = [
        "row_id", "subject_id", "visit", "treatment", "measurement_group",
        "age", "bmi", "baseline", "score", "response", "count_outcome",
        "person_time", "outcome", "marker1", "marker2", "follow_time",
        "event", "competing_time", "competing_status", "ordinal_outcome",
        "nominal_outcome", "continuous_outcome", "mediator", "sem_outcome",
        "x1", "x2", "x3", "x4", "item1", "item2", "item3", "item4",
        "item5", "item6", "item7", "item8",
    ]
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        for row_id in range(1, 321):
            subject_id = (row_id - 1) // 4 + 1
            visit = (row_id - 1) % 4
            treated = subject_id % 2 == 0
            treatment = "treated" if treated else "control"
            measurement_group = "G2" if subject_id % 2 == 0 else "G1"
            age = 45 + (subject_id % 25) * 0.65 + rng.gauss(0, 1.8)
            baseline = rng.gauss(0, 1)
            bmi_value = 23 + 0.04 * (age - 55) + rng.gauss(0, 2)
            subject_effect = math.sin(subject_id / 7) * 1.4
            latent = 0.45 * baseline + 0.25 * treated + rng.gauss(0, 1)
            items = [0.8 * latent + rng.gauss(0, 0.55) for _ in range(8)]
            x1 = rng.gauss(0, 1)
            x2 = 0.55 * x1 + rng.gauss(0, 0.75)
            x3 = -0.30 * x1 + 0.45 * x2 + rng.gauss(0, 0.75)
            x4 = 0.50 * x3 + rng.gauss(0, 0.8)
            score = 50 + subject_effect + 1.1 * visit + 2.0 * treated + 0.7 * visit * treated + rng.gauss(0, 2)
            response = int(rng.random() < logistic(-1.1 + 0.32 * visit + 0.5 * treated))
            person_time = rng.uniform(0.8, 1.3)
            count_outcome = poisson_sample(
                rng, math.exp(-0.15 + 0.2 * treated + 0.15 * baseline) * person_time
            )
            event_probability = logistic(-1.2 + 0.5 * treated + 0.25 * baseline + 0.2 * x1)
            outcome = int(rng.random() < event_probability)
            marker1 = rng.gauss(1.1 if outcome else 0.0, 1.0)
            marker2 = rng.gauss(0.7 if outcome else 0.0, 1.1)
            hazard = 0.08 * math.exp(0.35 * treated + 0.015 * (age - 55))
            event_time = -math.log(max(rng.random(), 1e-9)) / hazard
            censor_time = rng.uniform(4, 20)
            event = int(event_time <= censor_time)
            follow_time = min(event_time, censor_time)
            risk_draw = rng.random()
            competing_status = 1 if risk_draw < 0.32 else 2 if risk_draw < 0.52 else 0
            competing_time = rng.uniform(1, 24)
            continuous_outcome = 2 + 0.8 * treated + 0.35 * baseline + 0.25 * x1 + rng.gauss(0, 1)
            mediator = 0.65 * latent + 0.02 * (age - 55) + rng.gauss(0, 0.7)
            sem_outcome = 0.55 * mediator + 0.25 * latent + rng.gauss(0, 0.8)
            ordinal_outcome = "low" if latent < -0.4 else "middle" if latent < 0.6 else "high"
            nominal_outcome = "A" if baseline < -0.45 else "B" if baseline < 0.55 else "C"
            row = {
                "row_id": row_id, "subject_id": subject_id, "visit": visit,
                "treatment": treatment, "measurement_group": measurement_group,
                "age": round(age, 6),
                "bmi": "" if row_id % 17 == 0 else round(bmi_value, 6),
                "baseline": round(baseline, 6), "score": round(score, 6),
                "response": response, "count_outcome": count_outcome,
                "person_time": round(person_time, 6), "outcome": outcome,
                "marker1": round(marker1, 6), "marker2": round(marker2, 6),
                "follow_time": round(follow_time, 6), "event": event,
                "competing_time": round(competing_time, 6),
                "competing_status": competing_status,
                "ordinal_outcome": ordinal_outcome, "nominal_outcome": nominal_outcome,
                "continuous_outcome": round(continuous_outcome, 6),
                "mediator": round(mediator, 6), "sem_outcome": round(sem_outcome, 6),
                "x1": round(x1, 6), "x2": round(x2, 6),
                "x3": round(x3, 6), "x4": round(x4, 6),
            }
            row.update({f"item{index}": round(value, 6) for index, value in enumerate(items, 1)})
            writer.writerow(row)


def build_config(module_id: str, parameters: dict) -> dict:
    return {
        "run": {"run_id": f"matrix_{module_id}", "random_seed": 20260803},
        "analysis": {"parameters": {module_id: parameters}},
        "variables": {
            "id": "subject_id", "time": "visit", "event": "event",
            "reference_levels": {"treatment": "control"}, "labels": {},
        },
        "data_handling": {"multiple_testing": {"method": "holm"}},
        "reporting": {
            "figure_contract": {
                "template": "medical-academic-v1", "backend": "R",
                "profile": "analysis", "formats": ["png"],
                "width_mm": 160, "height_mm": 120, "dpi": 120,
                "require_source_data": True,
                "require_statistics_metadata": True,
                "require_editable_text": False,
            }
        },
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="执行真实 R 模块测试矩阵。")
    parser.add_argument("--shard", choices=["core", "measurement", "clinical", "advanced"])
    parser.add_argument("--module")
    parser.add_argument("--rscript", default=os.environ.get("RSCRIPT", "Rscript"))
    parser.add_argument("--r-library", type=Path)
    parser.add_argument("--work-dir", type=Path, default=DEFAULT_WORK_DIR)
    parser.add_argument("--keep", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    matrix = yaml.safe_load(MATRIX_PATH.read_text(encoding="utf-8-sig"))["modules"]
    selected = [
        module_id for module_id, scenario in matrix.items()
        if (args.module is None or module_id == args.module)
        and (args.shard is None or scenario["shard"] == args.shard)
    ]
    if not selected:
        raise SystemExit("No modules selected")
    work_dir = args.work_dir.resolve()
    if work_dir.exists() and not args.keep:
        shutil.rmtree(work_dir)
    work_dir.mkdir(parents=True, exist_ok=True)
    data_path = work_dir / "synthetic_matrix.csv"
    generate_dataset(data_path)
    environment = os.environ.copy()
    for locale_name in ("LC_ALL", "LC_CTYPE"):
        if environment.get(locale_name, "").lower() in {"c.utf-8", "c.utf8"}:
            environment.pop(locale_name, None)
    if args.r_library:
        environment["R_LIBS_USER"] = str(args.r_library.resolve())
    results: dict[str, dict] = {}
    for module_id in selected:
        scenario = matrix[module_id]
        module_dir = work_dir / module_id
        module_dir.mkdir(parents=True, exist_ok=True)
        config_path = module_dir / "config.json"
        config_path.write_text(
            json.dumps(build_config(module_id, scenario["parameters"]), ensure_ascii=False, indent=2),
            encoding="utf-8",
        )
        completed = subprocess.run(
            [
                args.rscript, str(R_RUNNER), "--skill-root", str(SKILL_ROOT),
                "--module", module_id, "--config", str(config_path),
                "--data", str(data_path), "--run-dir", str(module_dir),
            ],
            cwd=REPO_ROOT, env=environment, capture_output=True, text=True,
            encoding="utf-8", errors="replace", check=False, timeout=900,
        )
        if completed.returncode != 0:
            print(completed.stdout)
            print(completed.stderr, file=sys.stderr)
            raise SystemExit(f"Real R execution failed: {module_id}")
        result_path = module_dir / f"{module_id}_result.json"
        result = json.loads(result_path.read_text(encoding="utf-8"))
        if result["method_id"] != scenario["expected_method_id"]:
            raise SystemExit(
                f"Unexpected method_id for {module_id}: {result['method_id']}"
            )
        for figure in result.get("figures", []):
            if figure.get("template") != "medical-academic-v1":
                raise SystemExit(f"Figure template mismatch: {module_id}")
            if not (module_dir / figure["source_data_path"]).is_file():
                raise SystemExit(f"Figure Source Data missing: {module_id}")
        results[module_id] = {
            "status": result["status"], "method_id": result["method_id"],
            "tables": len(result["tables"]), "figures": len(result.get("figures", [])),
        }
        print(completed.stdout.strip())
    summary = {"status": "pass", "modules": results}
    (work_dir / "matrix_summary.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print(json.dumps(summary, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
