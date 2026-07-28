#!/usr/bin/env python3
"""Detect format-specific Python capabilities without mutating the environment."""

from __future__ import annotations

import argparse
import importlib.metadata
import importlib.util
import json
import platform
import sys
from datetime import UTC, datetime
from pathlib import Path


CORE_PACKAGES = {
    "pandas": {"import": "pandas", "minimum_version": "2.0.0"},
    "PyYAML": {"import": "yaml", "minimum_version": "6.0.0"},
    "openpyxl": {"import": "openpyxl", "minimum_version": "3.1.0"},
    "python-docx": {"import": "docx", "minimum_version": "1.1.0"},
}
FORMAT_PACKAGES = {
    "csv": [], "tsv": [], "txt": [], "dat": [], "json": [], "jsonl": [],
    "xlsx": ["openpyxl"],
    "xls": ["xlrd"],
    "sav": ["pyreadstat"],
    "dta": ["pyreadstat"],
    "sas7bdat": ["pyreadstat"],
    "xpt": ["pyreadstat"],
    "parquet": ["pyarrow"],
    "feather": ["pyarrow"],
}
EXTRA_PACKAGES = {
    "xlrd": {"import": "xlrd", "minimum_version": "2.0.0"},
    "pyreadstat": {"import": "pyreadstat", "minimum_version": "1.2.0"},
    "pyarrow": {"import": "pyarrow", "minimum_version": "12.0.0"},
}


def utc_now() -> str:
    return datetime.now(UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def version_for(distribution: str) -> str | None:
    try:
        return importlib.metadata.version(distribution)
    except importlib.metadata.PackageNotFoundError:
        return None


def meets_minimum(version: str | None, minimum: str) -> bool:
    if version is None:
        return False
    def normalized(value: str) -> tuple[int, ...]:
        parts = []
        for component in value.split("."):
            digits = "".join(character for character in component if character.isdigit())
            parts.append(int(digits or 0))
        return tuple(parts)
    observed, required = normalized(version), normalized(minimum)
    return observed + (0,) * max(0, len(required) - len(observed)) >= required + (0,) * max(0, len(observed) - len(required))


def capability(format_name: str) -> dict:
    normalized = format_name.lower().lstrip(".")
    # These packages are required by the confirmed pipeline itself; reader extras
    # are added only for the detected input format.
    required_names = [*CORE_PACKAGES, *FORMAT_PACKAGES.get(normalized, [])]
    registry = {**CORE_PACKAGES, **EXTRA_PACKAGES}
    packages = []
    for name in dict.fromkeys(required_names):
        definition = registry[name]
        module_name = definition["import"]
        installed = importlib.util.find_spec(module_name) is not None
        version = version_for(name) if installed else None
        packages.append(
            {
                "name": name,
                "minimum_version": definition["minimum_version"],
                "import_name": module_name,
                "installed": installed,
                "version": version,
                "meets_minimum": meets_minimum(version, definition["minimum_version"]),
            }
        )
    return {
        "input_format": normalized,
        "supported": normalized in FORMAT_PACKAGES,
        "required_packages": packages,
        "missing_packages": [item["name"] for item in packages if not item["meets_minimum"]],
        "capable": normalized in FORMAT_PACKAGES and all(item["meets_minimum"] for item in packages),
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="检测医学分析输入格式的 Python 依赖能力。")
    parser.add_argument("--input", required=True, help="Input file path")
    parser.add_argument("--output", required=True, help="Output JSON path")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    input_path = Path(args.input).expanduser().resolve()
    result = capability(input_path.suffix)
    result.update(
        {
            "schema_version": "1.0",
            "generated_at_utc": utc_now(),
            "input_path": str(input_path),
            "python": {
                "executable": sys.executable,
                "version": platform.python_version(),
                "implementation": platform.python_implementation(),
            },
        }
    )
    output = Path(args.output).expanduser().resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
    lock = {
        "schema_version": "1.0",
        "generated_at_utc": result["generated_at_utc"],
        "python_executable": sys.executable,
        "input_format": result["input_format"],
        "packages": [
            {"name": item["name"], "version": item["version"], "minimum_version": item["minimum_version"]}
            for item in result["required_packages"]
        ],
    }
    (output.parent / "python_requirements.lock.json").write_text(
        json.dumps(lock, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    print(json.dumps(result, ensure_ascii=False))
    return 0 if result["supported"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
