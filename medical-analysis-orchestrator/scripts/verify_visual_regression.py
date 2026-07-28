#!/usr/bin/env python3
"""Render DOCX/XLSX through LibreOffice and compare page raster fingerprints when available."""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import subprocess
from datetime import UTC, datetime
from pathlib import Path


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while block := handle.read(1024 * 1024):
            digest.update(block)
    return digest.hexdigest()


def soffice_path() -> str | None:
    candidates = [
        shutil.which("soffice"),
        r"C:\Program Files\LibreOffice\program\soffice.exe",
        r"C:\Program Files (x86)\LibreOffice\program\soffice.exe",
    ]
    for item in candidates:
        if item and Path(item).is_file():
            return item
    return None


def render(source: Path, output_dir: Path, soffice: str) -> tuple[Path | None, str | None]:
    completed = subprocess.run(
        [soffice, "--headless", "--convert-to", "pdf", "--outdir", str(output_dir), str(source)],
        capture_output=True, text=True, encoding="utf-8", errors="replace", check=False, timeout=120,
    )
    pdf = output_dir / f"{source.stem}.pdf"
    if completed.returncode != 0 or not pdf.is_file():
        return None, (completed.stderr or completed.stdout)[-1000:]
    return pdf, None


def raster_fingerprints(pdf: Path, output_dir: Path) -> tuple[list[dict], str | None]:
    try:
        import fitz  # PyMuPDF is intentionally optional.
    except ImportError:
        return [], "PyMuPDF is unavailable; PDF was rendered but page raster comparison was not run"
    document = fitz.open(pdf)
    pages = []
    for index, page in enumerate(document, start=1):
        pixmap = page.get_pixmap(matrix=fitz.Matrix(1.5, 1.5), alpha=False)
        image_path = output_dir / f"{pdf.stem}_page_{index:03d}.png"
        pixmap.save(image_path)
        pages.append({
            "page": index,
            "width": pixmap.width,
            "height": pixmap.height,
            "sha256": sha256_file(image_path),
            "path": image_path.name,
        })
    document.close()
    return pages, None


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Word/XLSX 页面渲染与视觉回归检查。")
    parser.add_argument("--docx")
    parser.add_argument("--xlsx", action="append", default=[])
    parser.add_argument("--output", required=True)
    parser.add_argument("--baseline", help="Optional expected JSON baseline")
    parser.add_argument("--update-baseline", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    sources = [Path(item).resolve() for item in ([args.docx] if args.docx else []) + args.xlsx]
    if not sources or any(not source.is_file() for source in sources):
        raise SystemExit("必须提供存在的 --docx 和/或 --xlsx 文件。")
    output = Path(args.output).resolve(); output.mkdir(parents=True, exist_ok=True)
    soffice = soffice_path()
    payload = {
        "schema_version": "1.0",
        "generated_at_utc": datetime.now(UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
        "renderer": "LibreOffice",
        "renderer_available": bool(soffice),
        "artifacts": [],
        "status": "unavailable" if not soffice else "pass",
    }
    if soffice:
        for source in sources:
            artifact_dir = output / source.stem; artifact_dir.mkdir(parents=True, exist_ok=True)
            pdf, error = render(source, artifact_dir, soffice)
            artifact = {"source": str(source), "source_sha256": sha256_file(source), "pdf": None, "pages": [], "error": error}
            if pdf:
                pages, raster_error = raster_fingerprints(pdf, artifact_dir)
                artifact.update({"pdf": str(pdf.relative_to(output)), "pages": pages, "raster_error": raster_error})
            else:
                payload["status"] = "fail"
            payload["artifacts"].append(artifact)
    baseline_path = Path(args.baseline).resolve() if args.baseline else None
    if baseline_path and baseline_path.is_file() and payload["status"] == "pass":
        baseline = json.loads(baseline_path.read_text(encoding="utf-8"))
        observed = [[page["sha256"] for page in item.get("pages", [])] for item in payload["artifacts"]]
        expected = [[page["sha256"] for page in item.get("pages", [])] for item in baseline.get("artifacts", [])]
        if observed != expected:
            payload["status"] = "fail"; payload["baseline_mismatch"] = True
    if args.update_baseline:
        if not baseline_path:
            raise SystemExit("--update-baseline requires --baseline")
        baseline_path.parent.mkdir(parents=True, exist_ok=True)
        baseline_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    result_path = output / "visual_regression.json"
    result_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps({"status": payload["status"], "report": str(result_path)}, ensure_ascii=False))
    return 0 if payload["status"] in {"pass", "unavailable"} else 2


if __name__ == "__main__":
    raise SystemExit(main())
