#!/usr/bin/env python3
"""Synchronize the approved development Skill into the release repository."""

from __future__ import annotations

import argparse
import shutil
from pathlib import Path

from check_distribution_sync import inventory, is_ignored


REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_DESTINATION = REPO_ROOT / "medical-analysis-orchestrator"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="将开发目录中的 Skill 源文件同步到发布仓库。"
    )
    parser.add_argument("--development", type=Path, required=True)
    parser.add_argument("--destination", type=Path, default=DEFAULT_DESTINATION)
    parser.add_argument("--apply", action="store_true")
    return parser.parse_args()


def validate_roots(source: Path, destination: Path) -> None:
    if source.name != "01medical-analysis-orchestrator":
        raise SystemExit(f"Unexpected development directory: {source}")
    if destination != DEFAULT_DESTINATION.resolve():
        raise SystemExit(f"Destination must be the release Skill directory: {destination}")
    if not (source / "SKILL.md").is_file() or not (destination / "SKILL.md").is_file():
        raise SystemExit("Both source and destination must contain SKILL.md")


def main() -> int:
    args = parse_args()
    source = args.development.resolve()
    destination = args.destination.resolve()
    validate_roots(source, destination)
    source_files = inventory(source)
    destination_files = inventory(destination)
    copy_paths = sorted(
        name for name, metadata in source_files.items()
        if destination_files.get(name) != metadata
    )
    remove_paths = sorted(set(destination_files) - set(source_files))
    print(f"copy={len(copy_paths)} remove={len(remove_paths)}")
    for name in copy_paths:
        print(f"COPY {name}")
    for name in remove_paths:
        print(f"REMOVE {name}")
    if not args.apply:
        return 1 if copy_paths or remove_paths else 0

    for name in copy_paths:
        source_path = source / Path(name)
        destination_path = destination / Path(name)
        destination_path.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source_path, destination_path)
    for name in remove_paths:
        destination_path = (destination / Path(name)).resolve()
        destination_path.relative_to(destination)
        destination_path.unlink()
    for directory in sorted(
        (path for path in destination.rglob("*") if path.is_dir()),
        key=lambda path: len(path.parts),
        reverse=True,
    ):
        relative = directory.relative_to(destination)
        if is_ignored(relative):
            continue
        try:
            directory.rmdir()
        except OSError:
            pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
