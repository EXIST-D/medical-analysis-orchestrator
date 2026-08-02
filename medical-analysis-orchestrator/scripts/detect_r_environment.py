#!/usr/bin/env python3
"""Discover a usable Rscript without hard-coding a machine-specific path."""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

try:
    import yaml
except ImportError:
    yaml = None


def utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def load_config(path: Path | None) -> dict[str, Any]:
    if path is None:
        return {}
    text = path.read_text(encoding="utf-8-sig")
    payload = yaml.safe_load(text) if yaml is not None else json.loads(text)
    return payload if isinstance(payload, dict) else {}


def nested_get(payload: dict[str, Any], path: str, default: Any = None) -> Any:
    current: Any = payload
    for key in path.split("."):
        if not isinstance(current, dict) or key not in current:
            return default
        current = current[key]
    return current


def normalize_rscript(candidate: Path) -> Path:
    if candidate.is_dir():
        names = ["Rscript.exe", "Rscript"] if os.name == "nt" else ["Rscript", "Rscript.exe"]
        for relative in ("bin", "bin/x64", ""):
            for name in names:
                path = candidate / relative / name
                if path.exists():
                    return path
    return candidate


def configured_candidates(
    config: dict[str, Any], config_path: Path | None
) -> list[tuple[str, Path]]:
    value = nested_get(config, "runtime.r_executable", "auto")
    if not value or str(value).lower() == "auto":
        return []
    path = Path(str(value)).expanduser()
    if not path.is_absolute() and config_path is not None:
        path = config_path.parent / path
    return [("config", normalize_rscript(path.resolve()))]


def r_home_candidates() -> list[tuple[str, Path]]:
    value = os.environ.get("R_HOME")
    if not value:
        return []
    return [("R_HOME", normalize_rscript(Path(value).expanduser()))]


def path_candidates() -> list[tuple[str, Path]]:
    value = shutil.which("Rscript")
    return [("PATH", Path(value).resolve())] if value else []


def windows_registry_candidates() -> list[tuple[str, Path]]:
    if os.name != "nt":
        return []
    keys = [
        r"HKCU\SOFTWARE\R-core\R",
        r"HKLM\SOFTWARE\R-core\R",
        r"HKLM\SOFTWARE\WOW6432Node\R-core\R",
    ]
    result: list[tuple[str, Path]] = []
    for key in keys:
        try:
            completed = subprocess.run(
                ["reg", "query", key, "/s", "/v", "InstallPath"],
                capture_output=True,
                text=True,
                timeout=8,
                check=False,
            )
        except (OSError, subprocess.SubprocessError):
            continue
        for line in completed.stdout.splitlines():
            match = re.search(r"InstallPath\s+REG_\w+\s+(.+)$", line.strip())
            if match:
                result.append(
                    (f"registry:{key}", normalize_rscript(Path(match.group(1).strip())))
                )
    return result


def common_install_candidates() -> list[tuple[str, Path]]:
    roots: list[Path] = []
    if os.name == "nt":
        for env_name in ("ProgramFiles", "ProgramFiles(x86)", "LOCALAPPDATA"):
            value = os.environ.get(env_name)
            if value:
                roots.append(Path(value) / "R")
        system_drive = os.environ.get("SystemDrive")
        if system_drive:
            roots.append(Path(system_drive + "\\") / "R")
        for drive_letter in "ABCDEFGHIJKLMNOPQRSTUVWXYZ":
            drive_root = Path(f"{drive_letter}:\\")
            if drive_root.exists():
                roots.append(drive_root / "R")
    else:
        roots.extend([Path("/usr/local/bin"), Path("/usr/bin"), Path("/opt/R")])

    candidates: list[tuple[str, Path]] = []
    for root in roots:
        if not root.exists():
            continue
        if root.is_file():
            candidates.append(("common_install", root))
            continue
        patterns = ["Rscript.exe", "Rscript"]
        for pattern in patterns:
            for path in root.glob(f"R-*/bin/{pattern}"):
                candidates.append(("common_install", path.resolve()))
            for path in root.glob(f"R-*/bin/x64/{pattern}"):
                candidates.append(("common_install", path.resolve()))
    return sorted(candidates, key=lambda item: str(item[1]), reverse=True)


def parse_version(text: str) -> str | None:
    match = re.search(
        r"(?:Rscript\s+\(R\)|R scripting front-end|R)\s+version\s+"
        r"([0-9]+(?:\.[0-9]+){1,3})",
        text,
        re.IGNORECASE,
    )
    if not match:
        match = re.search(r"R version\s+([0-9]+(?:\.[0-9]+){1,3})", text)
    return match.group(1) if match else None


def version_tuple(value: str | None) -> tuple[int, ...]:
    if not value:
        return ()
    return tuple(int(part) for part in value.split("."))


def probe_candidate(source: str, path: Path, minimum_version: str) -> dict[str, Any]:
    record = {
        "source": source,
        "path": str(path),
        "exists": path.exists(),
        "runnable": False,
        "version": None,
        "meets_minimum": False,
        "error": None,
    }
    if not path.exists():
        record["error"] = "path_not_found"
        return record
    try:
        completed = subprocess.run(
            [str(path), "--version"],
            capture_output=True,
            text=True,
            timeout=15,
            check=False,
        )
        version = parse_version((completed.stdout or "") + "\n" + (completed.stderr or ""))
        record["version"] = version
        record["runnable"] = completed.returncode == 0 and version is not None
        record["meets_minimum"] = (
            record["runnable"]
            and version_tuple(version) >= version_tuple(minimum_version)
        )
        if not record["runnable"]:
            record["error"] = f"exit_code={completed.returncode}; version_unparsed"
    except Exception as exc:
        record["error"] = f"{type(exc).__name__}: {exc}"
    return record


def selected_packages(config: dict[str, Any], skill_root: Path) -> list[dict[str, str]]:
    modules = nested_get(config, "analysis.modules", []) or []
    module_ids = [
        str(item if isinstance(item, str) else item.get("id"))
        for item in modules
        if isinstance(item, str) or (isinstance(item, dict) and item.get("id"))
    ]
    packages: dict[str, str] = {
        "yaml": "2.3.0",
        "jsonlite": "1.8.0",
        "digest": "0.6.30",
    }
    for module_id in module_ids:
        descriptor = skill_root / "modules" / module_id / "module.yml"
        if not descriptor.exists():
            continue
        try:
            payload = load_config(descriptor)
            for item in payload.get("required_packages", []):
                if isinstance(item, str):
                    packages.setdefault(item, "0")
                elif isinstance(item, dict) and item.get("name"):
                    packages[str(item["name"])] = str(
                        item.get("minimum_version", "0")
                    )
        except Exception:
            continue
    figure_contract = ((config.get("reporting") or {}).get("figure_contract") or {})
    figure_template = str(figure_contract.get("template") or "medical-academic-v1").lower()
    if figure_template == "medical-academic-v1":
        for name, minimum in {
            "ggplot2": "3.4.0",
            "patchwork": "1.1.0",
            "ragg": "1.2.0",
            "svglite": "2.1.0",
            "png": "0.1.8",
        }.items():
            packages.setdefault(name, minimum)
    return [
        {"name": name, "minimum_version": packages[name]}
        for name in sorted(packages)
    ]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Discover and probe Rscript.")
    parser.add_argument("--config", help="analysis_plan.yml")
    parser.add_argument("--output", required=True, help="Runtime output directory")
    parser.add_argument("--packages", default="", help="Additional comma-separated packages")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    config_path = Path(args.config).expanduser().resolve() if args.config else None
    config = load_config(config_path)
    output_dir = Path(args.output).expanduser().resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    skill_root = Path(__file__).resolve().parent.parent
    minimum_version = str(nested_get(config, "runtime.minimum_version", "4.3.0"))

    project_dir_value = nested_get(config, "runtime.project_dir")
    if project_dir_value:
        project_dir = Path(str(project_dir_value)).expanduser()
        if not project_dir.is_absolute() and config_path is not None:
            project_dir = config_path.parent / project_dir
        project_dir = project_dir.resolve()
    elif config_path is not None:
        project_dir = config_path.parent
    else:
        project_dir = Path.cwd()

    project_signals = {
        ".Rprofile": (project_dir / ".Rprofile").exists(),
        "renv.lock": (project_dir / "renv.lock").exists(),
        "renv/activate.R": (project_dir / "renv" / "activate.R").exists(),
    }

    raw_candidates = (
        configured_candidates(config, config_path)
        + r_home_candidates()
        + path_candidates()
        + windows_registry_candidates()
        + common_install_candidates()
    )
    seen: set[str] = set()
    probes = []
    for source, candidate in raw_candidates:
        key = str(candidate).lower() if os.name == "nt" else str(candidate)
        if key in seen:
            continue
        seen.add(key)
        probes.append(probe_candidate(source, candidate, minimum_version))

    selected = next((item for item in probes if item["meets_minimum"]), None)
    packages = selected_packages(config, skill_root)
    known_names = {item["name"] for item in packages}
    for package in (item.strip() for item in args.packages.split(",") if item.strip()):
        if package not in known_names:
            packages.append({"name": package, "minimum_version": "0"})
            known_names.add(package)
    packages = sorted(packages, key=lambda item: item["name"])

    project_library_value = str(
        nested_get(config, "runtime.project_library", ".r-library")
    )
    project_library = Path(project_library_value).expanduser()
    if not project_library.is_absolute():
        project_library = (skill_root / project_library).resolve()

    payload = {
        "schema_version": "1.0",
        "checked_at_utc": utc_now(),
        "minimum_version": minimum_version,
        "project_dir": str(project_dir),
        "project_signals": project_signals,
        "selected": selected,
        "candidates": probes,
        "required_packages": packages,
        "project_library": str(project_library),
        "status": "ready" if selected else "not_found_or_incompatible",
    }
    environment_path = output_dir / "r_environment.json"
    environment_path.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )

    if selected:
        probe_script = Path(__file__).resolve().parent / "detect_r_environment.R"
        command = [
            selected["path"],
            str(probe_script),
            "--output",
            str(output_dir),
            "--packages",
            ",".join(item["name"] for item in packages),
            "--library",
            str(project_library),
        ]
        r_environment = os.environ.copy()
        if os.name == "nt":
            for name in ("LC_ALL", "LC_CTYPE"):
                if r_environment.get(name, "").lower() in {"c.utf-8", "c.utf8"}:
                    r_environment.pop(name, None)
        r_environment["R_LIBS_USER"] = str(project_library)
        completed = subprocess.run(
            command,
            capture_output=True,
            text=True,
            check=False,
            env=r_environment,
        )
        (output_dir / "r_probe.log").write_text(
            (completed.stdout or "") + (completed.stderr or ""),
            encoding="utf-8",
        )
        if completed.returncode != 0:
            payload["status"] = "probe_failed"
            payload["probe_exit_code"] = completed.returncode
            environment_path.write_text(
                json.dumps(payload, ensure_ascii=False, indent=2),
                encoding="utf-8",
            )
            print(json.dumps(payload, ensure_ascii=False, indent=2))
            return 4

    print(json.dumps(payload, ensure_ascii=False, indent=2))
    return 0 if selected else 3


if __name__ == "__main__":
    raise SystemExit(main())
