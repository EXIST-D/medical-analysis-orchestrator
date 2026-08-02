#!/usr/bin/env python3
"""Build a deterministic installable Skill archive for a tagged release."""

from __future__ import annotations

import argparse
import hashlib
import zipfile
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SKILL_ROOT = REPO_ROOT / "medical-analysis-orchestrator"
IGNORED_DIRECTORIES = {".git", ".r-library", ".pytest_cache", "__pycache__"}
IGNORED_NAMES = {".coverage", "Rplots.pdf", "Thumbs.db", ".DS_Store"}
IGNORED_SUFFIXES = {".pyc", ".pyo", ".log", ".tmp", ".bak"}


def is_allowed(relative_path: Path) -> bool:
    return not (
        any(part in IGNORED_DIRECTORIES for part in relative_path.parts)
        or relative_path.name in IGNORED_NAMES
        or relative_path.suffix.lower() in IGNORED_SUFFIXES
    )


def archive_files() -> list[tuple[Path, Path]]:
    files: list[tuple[Path, Path]] = []
    for name in ("README.md", "README.en.md", "LICENSE", "VERSION", "release-manifest.json"):
        path = REPO_ROOT / name
        if not path.is_file():
            raise FileNotFoundError(f"Required release file is missing: {path}")
        files.append((path, Path(name)))
    for path in sorted(item for item in SKILL_ROOT.rglob("*") if item.is_file()):
        relative = path.relative_to(REPO_ROOT)
        if is_allowed(relative):
            files.append((path, relative))
    return files


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="打包可安装的 v0.0.5 Skill 发布资产。")
    parser.add_argument("--output", type=Path)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    version = (REPO_ROOT / "VERSION").read_text(encoding="utf-8-sig").strip()
    if version != "0.0.5":
        raise SystemExit(f"Refusing to package unexpected version: {version}")
    output = (
        args.output.resolve()
        if args.output
        else (REPO_ROOT.parent / f"medical-analysis-orchestrator-v{version}.zip").resolve()
    )
    output.parent.mkdir(parents=True, exist_ok=True)
    prefix = Path(f"medical-analysis-orchestrator-v{version}")
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for source, relative in archive_files():
            archive_path = (prefix / relative).as_posix()
            info = zipfile.ZipInfo(archive_path, date_time=(2026, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            archive.writestr(info, source.read_bytes())

    with zipfile.ZipFile(output) as archive:
        names = archive.namelist()
        forbidden = [
            name for name in names
            if "/.r-library/" in name or "/__pycache__/" in name
            or name.endswith(("Rplots.pdf", ".pyc", ".pyo"))
        ]
        if forbidden:
            output.unlink(missing_ok=True)
            raise SystemExit("Forbidden release paths: " + ", ".join(forbidden))
        if archive.testzip() is not None:
            output.unlink(missing_ok=True)
            raise SystemExit("Archive integrity check failed")

    digest = sha256_file(output)
    checksum = output.with_suffix(output.suffix + ".sha256")
    checksum.write_text(f"{digest}  {output.name}\n", encoding="ascii")
    print(f"archive={output}")
    print(f"sha256={digest}")
    print(f"files={len(archive_files())}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
