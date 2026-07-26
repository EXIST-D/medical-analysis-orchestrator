#!/usr/bin/env python3
"""Launch an R module through the discovered runtime with Windows-safe locale handling."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path


def sanitized_environment() -> dict[str, str]:
    environment = os.environ.copy()
    if os.name == "nt":
        for name in ("LC_ALL", "LC_CTYPE"):
            if environment.get(name, "").lower() in {"c.utf-8", "c.utf8"}:
                environment.pop(name, None)
    return environment


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run an R script using r_environment.json."
    )
    parser.add_argument("--runtime-profile", required=True)
    parser.add_argument("--script", required=True)
    parser.add_argument(
        "script_args",
        nargs=argparse.REMAINDER,
        help="Arguments after -- are forwarded to the R script",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    runtime_profile = Path(args.runtime_profile).expanduser().resolve()
    script_path = Path(args.script).expanduser().resolve()
    payload = json.loads(runtime_profile.read_text(encoding="utf-8"))
    selected = payload.get("selected") or {}
    rscript_value = selected.get("path")
    if payload.get("status") != "ready" or not rscript_value:
        raise SystemExit("R runtime profile is not ready; run detection again.")
    rscript_path = Path(rscript_value)
    if not rscript_path.is_file():
        raise SystemExit(f"Discovered Rscript no longer exists: {rscript_path}")
    if not script_path.is_file():
        raise SystemExit(f"R script not found: {script_path}")

    forwarded = list(args.script_args)
    if forwarded and forwarded[0] == "--":
        forwarded = forwarded[1:]
    config_path = None
    if "--config" in forwarded:
        index = forwarded.index("--config")
        if index + 1 < len(forwarded):
            config_path = Path(forwarded[index + 1]).expanduser().resolve()
    if config_path is not None:
        validator = Path(__file__).resolve().parent / "validate_config.py"
        validation = subprocess.run(
            [
                sys.executable,
                str(validator),
                str(config_path),
                "--mode",
                "execute",
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        if validation.returncode != 0:
            print(validation.stdout or validation.stderr)
            return validation.returncode

    environment = sanitized_environment()
    project_library = payload.get("project_library")
    if project_library:
        environment["R_LIBS_USER"] = str(project_library)
    completed = subprocess.run(
        [str(rscript_path), str(script_path), *forwarded],
        env=environment,
        check=False,
    )
    return completed.returncode


if __name__ == "__main__":
    raise SystemExit(main())
