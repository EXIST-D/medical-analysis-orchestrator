#!/usr/bin/env python3
"""Generate a repeatable release-readiness audit from the current Skill and test suite."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from datetime import UTC, datetime
from pathlib import Path

import yaml


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="生成 medical-analysis-orchestrator 最新自动审阅报告。")
    parser.add_argument("--skill-root", required=True)
    parser.add_argument("--test-root", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--run-tests", action="store_true")
    return parser.parse_args()


def run_tests(test_root: Path) -> dict:
    environment = os.environ.copy()
    environment["PYTHONUTF8"] = "1"
    completed = subprocess.run(
        [sys.executable, "-m", "unittest", "discover", "-s", str(test_root / "02_自动化测试"), "-p", "test_*.py", "-v"],
        cwd=test_root.parent / "01medical-analysis-orchestrator",
        env=environment,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        check=False,
        timeout=1800,
    )
    return {"returncode": completed.returncode, "stdout": completed.stdout, "stderr": completed.stderr}


def main() -> int:
    args = parse_args()
    skill_root = Path(args.skill_root).resolve()
    test_root = Path(args.test_root).resolve()
    modules = yaml.safe_load((skill_root / "modules" / "registry.yml").read_text(encoding="utf-8")) or {}
    ready = [item["id"] for item in modules.get("modules", []) if item.get("status") == "ready"]
    expected_scripts = [
        "inspect_data.py", "detect_python_environment.py", "install_python_packages.py",
        "detect_r_environment.py", "manage_renv.R", "run_pipeline.py",
        "write_environment_manifest.py", "validate_outputs.py", "build_report.py",
    ]
    missing_scripts = [name for name in expected_scripts if not (skill_root / "scripts" / name).is_file()]
    test_result = run_tests(test_root) if args.run_tests else None
    status = "pass" if not missing_scripts and (test_result is None or test_result["returncode"] == 0) else "fail"
    lines = [
        "# medical-analysis-orchestrator 自动审阅报告",
        "",
        f"- 生成时间（UTC）：{datetime.now(UTC).replace(microsecond=0).isoformat().replace('+00:00', 'Z')}",
        f"- 审阅状态：**{status}**",
        f"- Skill 根目录：`{skill_root}`",
        f"- 已登记 ready 模块：{', '.join(ready)}",
        "",
        "## 契约与运行时检查",
        "",
        f"- 核心脚本完整：{'是' if not missing_scripts else '否；缺少 ' + ', '.join(missing_scripts)}",
        f"- 配置模板存在：{'是' if (skill_root / 'templates' / 'analysis_config.yml').is_file() else '否'}",
        f"- 科学写作契约存在：{'是' if (skill_root / 'references' / 'scientific-writing-contract.md').is_file() else '否'}",
        f"- 结果对象契约存在：{'是' if (skill_root / 'references' / 'result-object-schema.md').is_file() else '否'}",
        "",
        "## 自动化测试",
        "",
    ]
    if test_result is None:
        lines.append("- 本次未执行测试；使用 `--run-tests` 生成含回归结果的审阅。")
    else:
        lines.extend([
            f"- 返回码：{test_result['returncode']}",
            "- 原始测试输出已写入同目录 JSON，作为可审计证据。",
        ])
    output = Path(args.output).resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text("\n".join(lines) + "\n", encoding="utf-8")
    if test_result is not None:
        (output.with_suffix(".json")).write_text(json.dumps(test_result, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps({"status": status, "report": str(output)}, ensure_ascii=False))
    return 0 if status == "pass" else 2


if __name__ == "__main__":
    raise SystemExit(main())
