#!/usr/bin/env python3
"""Install only declared missing Python reader/report dependencies into this interpreter."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from datetime import UTC, datetime
from pathlib import Path


ALLOWED_PACKAGES = {"pandas", "PyYAML", "openpyxl", "python-docx", "Pillow", "xlrd", "pyreadstat", "pyarrow"}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="按需安装 Python 输入格式依赖。")
    parser.add_argument("--profile", required=True, help="detect_python_environment JSON")
    parser.add_argument("--log-dir", required=True)
    parser.add_argument("--repository", default="https://pypi.org/simple")
    parser.add_argument("--allow-install", choices=["true", "false"], required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    profile = json.loads(Path(args.profile).read_text(encoding="utf-8"))
    missing = [str(name) for name in profile.get("missing_packages", [])]
    unexpected = sorted(set(missing) - ALLOWED_PACKAGES)
    if unexpected:
        raise SystemExit("拒绝未登记的 Python 依赖：" + ", ".join(unexpected))
    log_dir = Path(args.log_dir)
    log_dir.mkdir(parents=True, exist_ok=True)
    log = {
        "generated_at_utc": datetime.now(UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
        "python_executable": sys.executable,
        "requested": missing,
        "repository": args.repository,
        "installed": [],
        "status": "not_needed" if not missing else "pending",
    }
    if missing and args.allow_install != "true":
        log["status"] = "installation_not_authorized"
        (log_dir / "python_package_install_log.json").write_text(json.dumps(log, ensure_ascii=False, indent=2), encoding="utf-8")
        raise SystemExit("缺少 Python 依赖且未授权安装：" + ", ".join(missing))
    if missing:
        command = [sys.executable, "-m", "pip", "install", "--upgrade", "--index-url", args.repository, *missing]
        completed = subprocess.run(command, check=False, capture_output=True, text=True, encoding="utf-8", errors="replace")
        log["pip_stdout"] = completed.stdout[-4000:]
        log["pip_stderr"] = completed.stderr[-4000:]
        if completed.returncode != 0:
            log["status"] = "failed"
            (log_dir / "python_package_install_log.json").write_text(json.dumps(log, ensure_ascii=False, indent=2), encoding="utf-8")
            raise SystemExit(completed.returncode)
        log["installed"] = missing
        log["status"] = "installed"
    (log_dir / "python_package_install_log.json").write_text(json.dumps(log, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(log, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
