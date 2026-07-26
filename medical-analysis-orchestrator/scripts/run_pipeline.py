#!/usr/bin/env python3
"""Execute the confirmed R analysis, validate outputs, and build the report."""

from __future__ import annotations

import argparse
import csv
import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Any

import yaml


SCRIPT_DIR = Path(__file__).resolve().parent


def run(command: list[str], *, env: dict[str, str] | None = None) -> None:
    completed = subprocess.run(command, env=env, check=False)
    if completed.returncode != 0:
        raise SystemExit(completed.returncode)


def load_yaml(path: Path) -> dict[str, Any]:
    payload = yaml.safe_load(path.read_text(encoding="utf-8-sig"))
    return payload if isinstance(payload, dict) else {}


def version_tuple(value: str) -> tuple[int, ...]:
    parts = []
    for item in value.split("."):
        digits = "".join(character for character in item if character.isdigit())
        parts.append(int(digits or 0))
    return tuple(parts)


def package_install_plan(runtime_dir: Path) -> list[dict[str, str]]:
    profile = json.loads((runtime_dir / "r_environment.json").read_text(encoding="utf-8"))
    required = profile.get("required_packages", [])
    installed: dict[str, str] = {}
    versions_path = runtime_dir / "package_versions.csv"
    if versions_path.exists():
        with versions_path.open("r", encoding="utf-8-sig", newline="") as handle:
            for row in csv.DictReader(handle):
                if str(row.get("installed", "")).upper() == "TRUE":
                    installed[str(row["package"])] = str(row.get("version", "0"))
    result = []
    for item in required:
        name = str(item["name"])
        minimum = str(item.get("minimum_version", "0"))
        current = installed.get(name)
        if current is None or version_tuple(current) < version_tuple(minimum):
            result.append({"name": name, "minimum_version": minimum})
    return result


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="运行已确认的医学统计分析闭环。")
    parser.add_argument("--config", required=True)
    parser.add_argument("--skip-report", action="store_true")
    parser.add_argument("--no-install", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    config_path = Path(args.config).expanduser().resolve()
    config = load_yaml(config_path)
    run_dir_value = str((config.get("run") or {}).get("output_dir") or config_path.parent)
    run_dir = (
        Path(run_dir_value).expanduser().resolve()
        if Path(run_dir_value).is_absolute()
        else (config_path.parent / run_dir_value).resolve()
    )
    run_dir.mkdir(parents=True, exist_ok=True)
    if config_path.parent != run_dir or config_path.name != "analysis_plan.yml":
        destination = run_dir / "analysis_plan.yml"
        destination.write_text(config_path.read_text(encoding="utf-8-sig"), encoding="utf-8")
        config_path = destination

    run([sys.executable, str(SCRIPT_DIR / "validate_config.py"), str(config_path), "--mode", "execute"])
    run([sys.executable, str(SCRIPT_DIR / "prepare_data.py"), "--config", str(config_path)])

    runtime_dir = run_dir / "runtime"
    run(
        [
            sys.executable,
            str(SCRIPT_DIR / "detect_r_environment.py"),
            "--config",
            str(config_path),
            "--output",
            str(runtime_dir),
        ]
    )
    runtime_profile = json.loads((runtime_dir / "r_environment.json").read_text(encoding="utf-8"))
    install_plan = package_install_plan(runtime_dir)
    if install_plan:
        if args.no_install or not bool((config.get("runtime") or {}).get("auto_install_missing_packages", True)):
            names = ", ".join(item["name"] for item in install_plan)
            raise SystemExit(f"缺少或版本不足的 R 包：{names}")
        rscript = str((runtime_profile.get("selected") or {}).get("path"))
        project_library = str(runtime_profile["project_library"])
        install_env = os.environ.copy()
        install_env["R_LIBS_USER"] = project_library
        install_temp = run_dir / "runtime" / "r-install-tmp"
        install_temp.mkdir(parents=True, exist_ok=True)
        install_env["TMPDIR"] = str(install_temp)
        install_env["TMP"] = str(install_temp)
        install_env["TEMP"] = str(install_temp)
        for name in ("LC_ALL", "LC_CTYPE"):
            if install_env.get(name, "").lower() in {"c.utf-8", "c.utf8"}:
                install_env.pop(name, None)
        run(
            [
                rscript,
                str(SCRIPT_DIR / "install_packages.R"),
                "--packages",
                ",".join(item["name"] for item in install_plan),
                "--minimum-versions",
                ";".join(
                    f"{item['name']}={item['minimum_version']}" for item in install_plan
                ),
                "--library",
                project_library,
                "--repository",
                str((config.get("runtime") or {}).get("repository", "https://cloud.r-project.org")),
                "--log-dir",
                str(run_dir / "99_运行记录"),
                "--allow-install",
                "true",
            ],
            env=install_env,
        )
        run(
            [
                sys.executable,
                str(SCRIPT_DIR / "detect_r_environment.py"),
                "--config",
                str(config_path),
                "--output",
                str(runtime_dir),
            ]
        )

    prepared_path = run_dir / "01_数据整理" / "05_清洁分析数据.csv"
    run(
        [
            sys.executable,
            str(SCRIPT_DIR / "run_r.py"),
            "--runtime-profile",
            str(runtime_dir / "r_environment.json"),
            "--script",
            str(SCRIPT_DIR / "run_analysis.R"),
            "--",
            "--config",
            str(config_path),
            "--data",
            str(prepared_path),
        ]
    )
    run(
        [
            sys.executable,
            str(SCRIPT_DIR / "update_manifest.py"),
            "--run-dir",
            str(run_dir),
            "--phase",
            "execute",
        ]
    )
    run(
        [
            sys.executable,
            str(SCRIPT_DIR / "validate_outputs.py"),
            "--run-dir",
            str(run_dir),
            "--mode",
            "execute",
        ]
    )
    if not args.skip_report and bool((config.get("reporting") or {}).get("build_word_report", True)):
        run([sys.executable, str(SCRIPT_DIR / "build_report.py"), "--run-dir", str(run_dir)])
        run(
            [
                sys.executable,
                str(SCRIPT_DIR / "update_manifest.py"),
                "--run-dir",
                str(run_dir),
                "--phase",
                "report",
            ]
        )
        run(
            [
                sys.executable,
                str(SCRIPT_DIR / "validate_outputs.py"),
                "--run-dir",
                str(run_dir),
                "--mode",
                "report",
            ]
        )
    print(json.dumps({"status": "completed", "run_dir": str(run_dir)}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
