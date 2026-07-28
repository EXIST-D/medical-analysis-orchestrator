#!/usr/bin/env python3
"""Join R and Python runtime records into a single reproducibility manifest."""

from __future__ import annotations

import argparse
import hashlib
import json
from datetime import UTC, datetime
from pathlib import Path


def sha256_file(path: Path) -> str | None:
    if not path.is_file():
        return None
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while block := handle.read(1024 * 1024):
            digest.update(block)
    return digest.hexdigest()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="生成 R/Python 双环境可复现性清单。")
    parser.add_argument("--runtime-dir", required=True)
    parser.add_argument("--output", required=True)
    return parser.parse_args()


def read_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8")) if path.is_file() else {}


def main() -> int:
    args = parse_args()
    runtime = Path(args.runtime_dir).resolve()
    renv_lock = runtime.parent / "renv.lock"
    payload = {
        "schema_version": "1.0",
        "generated_at_utc": datetime.now(UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
        "python": read_json(runtime / "python_environment.json"),
        "r": read_json(runtime / "r_environment.json"),
        "renv": read_json(runtime / "renv_status.json"),
        "lockfiles": {
            "python_requirements": {
                "path": "runtime/python_requirements.lock.json",
                "sha256": sha256_file(runtime / "python_requirements.lock.json"),
            },
            "renv": {"path": "renv.lock", "sha256": sha256_file(renv_lock)},
        },
    }
    output = Path(args.output).resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
