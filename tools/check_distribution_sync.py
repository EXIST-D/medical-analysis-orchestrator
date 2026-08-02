#!/usr/bin/env python3
"""Compare development, release, manifest, and GitHub main states."""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys
from pathlib import Path
from typing import Iterable


REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_RELEASE_SKILL = REPO_ROOT / "medical-analysis-orchestrator"
IGNORED_DIRECTORIES = {
    ".git",
    ".r-library",
    ".pytest_cache",
    "__pycache__",
    "runtime",
    "runs",
    "outputs",
    "99_运行记录",
}
IGNORED_NAMES = {".coverage", "Rplots.pdf", "Thumbs.db", ".DS_Store"}
IGNORED_SUFFIXES = {".pyc", ".pyo", ".log", ".tmp", ".bak"}


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def is_ignored(relative_path: Path) -> bool:
    return (
        any(part in IGNORED_DIRECTORIES for part in relative_path.parts)
        or relative_path.name in IGNORED_NAMES
        or relative_path.suffix.lower() in IGNORED_SUFFIXES
    )


def inventory(root: Path) -> dict[str, dict[str, int | str]]:
    if not root.is_dir():
        raise FileNotFoundError(f"Directory does not exist: {root}")
    result: dict[str, dict[str, int | str]] = {}
    for path in sorted(item for item in root.rglob("*") if item.is_file()):
        relative = path.relative_to(root)
        if is_ignored(relative):
            continue
        key = relative.as_posix()
        result[key] = {"sha256": sha256_file(path), "size": path.stat().st_size}
    return result


def compare_inventories(
    left: dict[str, dict[str, int | str]],
    right: dict[str, dict[str, int | str]],
) -> dict[str, list[str]]:
    left_names = set(left)
    right_names = set(right)
    return {
        "only_in_development": sorted(left_names - right_names),
        "only_in_release": sorted(right_names - left_names),
        "content_mismatch": sorted(
            name
            for name in left_names & right_names
            if left[name]["sha256"] != right[name]["sha256"]
        ),
    }


def forbidden_release_paths(root: Path) -> list[str]:
    problems: list[str] = []
    for path in root.rglob("*"):
        relative = path.relative_to(root)
        if any(part == ".r-library" for part in relative.parts):
            problems.append(relative.as_posix())
        elif path.name in {"Rplots.pdf", ".coverage"}:
            problems.append(relative.as_posix())
    return sorted(set(problems))


def write_manifest(path: Path, version: str, files: dict[str, object]) -> None:
    payload = {
        "schema_version": "1.0",
        "project": "medical-analysis-orchestrator",
        "version": version,
        "source_root": "medical-analysis-orchestrator",
        "files": files,
    }
    path.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )


def validate_manifest(path: Path, version: str, files: dict[str, object]) -> list[str]:
    if not path.is_file():
        return [f"manifest missing: {path}"]
    payload = json.loads(path.read_text(encoding="utf-8-sig"))
    problems: list[str] = []
    if payload.get("version") != version:
        problems.append(
            f"manifest version {payload.get('version')!r} != {version!r}"
        )
    if payload.get("files") != files:
        problems.append("release-manifest.json does not match the release skill tree")
    return problems


def command_output(command: Iterable[str], cwd: Path) -> str:
    completed = subprocess.run(
        list(command), cwd=cwd, capture_output=True, text=True, encoding="utf-8",
        errors="replace", check=False,
    )
    if completed.returncode != 0:
        raise RuntimeError(completed.stderr.strip() or completed.stdout.strip())
    return completed.stdout.strip()


def remote_state(repo_root: Path, remote: str, branch: str) -> dict[str, object]:
    head = command_output(["git", "rev-parse", "HEAD"], repo_root)
    response = command_output(
        ["git", "ls-remote", remote, f"refs/heads/{branch}"], repo_root
    )
    remote_head = response.split()[0] if response else ""
    return {
        "local_head": head,
        "remote_head": remote_head,
        "synchronized": bool(remote_head) and head == remote_head,
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="检查开发 Skill、发布 Skill、清单与 GitHub main 是否一致。"
    )
    parser.add_argument("--development", type=Path)
    parser.add_argument("--release-skill", type=Path, default=DEFAULT_RELEASE_SKILL)
    parser.add_argument(
        "--manifest", type=Path, default=REPO_ROOT / "release-manifest.json"
    )
    parser.add_argument("--write-manifest", action="store_true")
    parser.add_argument("--check-remote", action="store_true")
    parser.add_argument("--remote", default="origin")
    parser.add_argument("--branch", default="main")
    parser.add_argument("--json-output", type=Path)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    release_skill = args.release_skill.resolve()
    version = (REPO_ROOT / "VERSION").read_text(encoding="utf-8-sig").strip()
    release_files = inventory(release_skill)
    if args.write_manifest:
        write_manifest(args.manifest.resolve(), version, release_files)

    report: dict[str, object] = {
        "status": "pass",
        "version": version,
        "release_files": len(release_files),
        "forbidden_release_paths": forbidden_release_paths(release_skill),
        "manifest_problems": validate_manifest(
            args.manifest.resolve(), version, release_files
        ),
    }
    if args.development:
        development_files = inventory(args.development.resolve())
        report["development_files"] = len(development_files)
        report["development_release_diff"] = compare_inventories(
            development_files, release_files
        )
    if args.check_remote:
        report["github_main"] = remote_state(REPO_ROOT, args.remote, args.branch)

    differences = report.get("development_release_diff", {})
    failed = bool(report["forbidden_release_paths"] or report["manifest_problems"])
    if isinstance(differences, dict):
        failed = failed or any(bool(value) for value in differences.values())
    github_state = report.get("github_main")
    if isinstance(github_state, dict):
        failed = failed or not bool(github_state.get("synchronized"))
    report["status"] = "fail" if failed else "pass"

    serialized = json.dumps(report, ensure_ascii=False, indent=2)
    if args.json_output:
        args.json_output.resolve().write_text(serialized + "\n", encoding="utf-8")
    print(serialized)
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
