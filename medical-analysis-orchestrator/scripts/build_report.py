#!/usr/bin/env python3
"""Build a minimal, traceable Chinese Word report from validated results."""

from __future__ import annotations

import argparse
import csv
import json
import math
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import yaml
from docx import Document
from docx.enum.table import WD_CELL_VERTICAL_ALIGNMENT, WD_TABLE_ALIGNMENT
from docx.enum.text import WD_ALIGN_PARAGRAPH
from docx.oxml import OxmlElement
from docx.oxml.ns import qn
from docx.shared import Cm, Inches, Pt


EAST_ASIA_FONT = "宋体"
LATIN_FONT = "Times New Roman"
BODY_SIZE = 12
TABLE_SIZE = 9
MODULE_TITLES = {
    "descriptive": "描述性统计",
    "group-comparison": "单因素分析",
    "correlation": "相关性分析",
    "linear-regression": "多元线性回归",
    "logistic-regression": "Logistic 回归",
    "reliability-validity": "信度与效度分析",
    "factor-analysis": "探索性与验证性因子分析",
    "mixed-effects": "混合效应模型",
    "missing-data": "缺失数据与多重插补",
    "generalized-regression": "广义回归",
    "survival": "基础生存分析",
    "diagnostic-accuracy": "诊断试验准确性",
    "gee": "广义估计方程",
    "measurement-invariance": "测量不变性",
    "competing-risks": "竞争风险分析",
    "propensity-score": "倾向评分分析",
    "sem": "结构方程模型",
    "network": "网络分析",
    "bayesian": "贝叶斯网络",
}


def utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def load_json(path: Path) -> dict[str, Any]:
    payload = json.loads(path.read_text(encoding="utf-8-sig"))
    return payload if isinstance(payload, dict) else {}


def load_yaml(path: Path) -> dict[str, Any]:
    payload = yaml.safe_load(path.read_text(encoding="utf-8-sig"))
    return payload if isinstance(payload, dict) else {}


def set_run_font(run: Any, size: float = BODY_SIZE, bold: bool | None = None) -> None:
    run.font.name = LATIN_FONT
    run.font.size = Pt(size)
    if bold is not None:
        run.bold = bold
    run_properties = run._element.get_or_add_rPr()
    fonts = run_properties.rFonts
    if fonts is None:
        fonts = OxmlElement("w:rFonts")
        run_properties.insert(0, fonts)
    fonts.set(qn("w:ascii"), LATIN_FONT)
    fonts.set(qn("w:hAnsi"), LATIN_FONT)
    fonts.set(qn("w:eastAsia"), EAST_ASIA_FONT)
    fonts.set(qn("w:cs"), LATIN_FONT)


def set_paragraph_format(
    paragraph: Any,
    *,
    indent: bool = True,
    alignment: Any | None = None,
    space_before: float = 0,
    space_after: float = 0,
) -> None:
    fmt = paragraph.paragraph_format
    fmt.line_spacing = 1.5
    fmt.space_before = Pt(space_before)
    fmt.space_after = Pt(space_after)
    fmt.first_line_indent = Pt(24) if indent else Pt(0)
    if alignment is not None:
        paragraph.alignment = alignment


def add_text_paragraph(
    document: Document,
    text: str,
    *,
    bold_prefix: str | None = None,
    indent: bool = True,
) -> Any:
    paragraph = document.add_paragraph()
    set_paragraph_format(paragraph, indent=indent)
    if bold_prefix:
        prefix_run = paragraph.add_run(bold_prefix)
        set_run_font(prefix_run, bold=True)
    content_run = paragraph.add_run(text)
    set_run_font(content_run)
    return paragraph


def add_heading(document: Document, text: str, level: int) -> Any:
    paragraph = document.add_paragraph()
    set_paragraph_format(
        paragraph,
        indent=False,
        space_before=6 if level == 1 else 3,
        space_after=0,
    )
    run = paragraph.add_run(text)
    set_run_font(run, size=14 if level == 1 else 12, bold=True)
    paragraph.paragraph_format.keep_with_next = True
    return paragraph


def set_cell_border(cell: Any, **edges: dict[str, Any]) -> None:
    tc_properties = cell._tc.get_or_add_tcPr()
    borders = tc_properties.first_child_found_in("w:tcBorders")
    if borders is None:
        borders = OxmlElement("w:tcBorders")
        tc_properties.append(borders)
    for edge_name, edge_data in edges.items():
        edge = borders.find(qn(f"w:{edge_name}"))
        if edge is None:
            edge = OxmlElement(f"w:{edge_name}")
            borders.append(edge)
        for key, value in edge_data.items():
            edge.set(qn(f"w:{key}"), str(value))


def set_table_width(table: Any, width_dxa: int, weights: list[float]) -> None:
    table.autofit = False
    table.alignment = WD_TABLE_ALIGNMENT.CENTER
    properties = table._tbl.tblPr
    table_width = properties.first_child_found_in("w:tblW")
    if table_width is None:
        table_width = OxmlElement("w:tblW")
        properties.append(table_width)
    table_width.set(qn("w:w"), str(width_dxa))
    table_width.set(qn("w:type"), "dxa")
    table_indent = properties.first_child_found_in("w:tblInd")
    if table_indent is None:
        table_indent = OxmlElement("w:tblInd")
        properties.append(table_indent)
    table_indent.set(qn("w:w"), "120")
    table_indent.set(qn("w:type"), "dxa")
    weight_total = sum(weights) or 1
    minimum_width = 500
    distributable = max(0, width_dxa - minimum_width * len(weights))
    exact_extras = [
        distributable * weight / weight_total for weight in weights
    ]
    column_widths = [
        minimum_width + int(extra) for extra in exact_extras
    ]
    remainder = width_dxa - sum(column_widths)
    fractional_order = sorted(
        range(len(weights)),
        key=lambda index: exact_extras[index] - int(exact_extras[index]),
        reverse=True,
    )
    for index in fractional_order[:remainder]:
        column_widths[index] += 1
    grid = table._tbl.tblGrid
    for index, grid_col in enumerate(grid):
        grid_col.set(qn("w:w"), str(column_widths[index]))
    for row in table.rows:
        for index, cell in enumerate(row.cells):
            column_width = column_widths[index]
            cell.width = Inches(column_width / 1440)
            tc_pr = cell._tc.get_or_add_tcPr()
            tc_w = tc_pr.first_child_found_in("w:tcW")
            if tc_w is None:
                tc_w = OxmlElement("w:tcW")
                tc_pr.append(tc_w)
            tc_w.set(qn("w:w"), str(column_width))
            tc_w.set(qn("w:type"), "dxa")


def format_table_cell(
    cell: Any, *, header: bool = False, font_size: float = TABLE_SIZE
) -> None:
    cell.vertical_alignment = WD_CELL_VERTICAL_ALIGNMENT.CENTER
    for paragraph in cell.paragraphs:
        set_paragraph_format(
            paragraph,
            indent=False,
            alignment=WD_ALIGN_PARAGRAPH.CENTER if header else WD_ALIGN_PARAGRAPH.LEFT,
        )
        for run in paragraph.runs:
            set_run_font(run, size=font_size, bold=header)


def display_value(value: str, *, header: bool = False) -> str:
    text = value.strip()
    if header:
        return text.replace("_", " ")
    if not text:
        return ""
    try:
        number = float(text)
    except ValueError:
        return text if len(text) <= 70 else text[:67] + "…"
    if not math.isfinite(number):
        return text
    if number.is_integer() and abs(number) < 1_000_000:
        return str(int(number))
    if number != 0 and abs(number) < 0.001:
        return f"{number:.3e}"
    rendered = f"{number:.3f}".rstrip("0").rstrip(".")
    return rendered


def table_column_weights(rows: list[list[str]], column_count: int) -> list[float]:
    weights = []
    for column_index in range(column_count):
        values = [
            row[column_index] if column_index < len(row) else ""
            for row in rows[:16]
        ]
        longest = max(
            (len(value) + sum(ord(char) > 127 for char in value) for value in values),
            default=5,
        )
        weights.append(float(min(24, max(6, longest))))
    return weights


def add_three_line_table(
    document: Document,
    rows: list[list[str]],
    *,
    max_rows: int = 25,
    max_columns: int = 10,
) -> None:
    if not rows:
        add_text_paragraph(document, "该结果表为空。")
        return
    selected = [
        [
            display_value(value, header=row_index == 0)
            for value in row[:max_columns]
        ]
        for row_index, row in enumerate(rows[: max_rows + 1])
    ]
    column_count = max(len(row) for row in selected)
    table = document.add_table(rows=len(selected), cols=column_count)
    set_table_width(table, 9030, table_column_weights(selected, column_count))
    table_font_size = 7.5 if column_count >= 8 else 8.5 if column_count >= 6 else 9
    for row_index, row in enumerate(selected):
        for column_index in range(column_count):
            value = row[column_index] if column_index < len(row) else ""
            cell = table.cell(row_index, column_index)
            cell.text = value
            format_table_cell(
                cell, header=row_index == 0, font_size=table_font_size
            )
            if row_index == 0:
                set_cell_border(
                    cell,
                    top={"val": "single", "sz": "12", "color": "000000"},
                    bottom={"val": "single", "sz": "6", "color": "000000"},
                    left={"val": "nil"},
                    right={"val": "nil"},
                )
            elif row_index == len(selected) - 1:
                set_cell_border(
                    cell,
                    bottom={"val": "single", "sz": "12", "color": "000000"},
                    top={"val": "nil"},
                    left={"val": "nil"},
                    right={"val": "nil"},
                )
            else:
                set_cell_border(
                    cell,
                    top={"val": "nil"},
                    bottom={"val": "nil"},
                    left={"val": "nil"},
                    right={"val": "nil"},
                )
    header_properties = table.rows[0]._tr.get_or_add_trPr()
    repeat = OxmlElement("w:tblHeader")
    repeat.set(qn("w:val"), "true")
    header_properties.append(repeat)
    if len(rows) > len(selected):
        add_text_paragraph(
            document,
            f"Word 报告仅展示前 {len(selected) - 1} 行，完整结果见对应 CSV/XLSX 文件。",
        )
    if len(rows[0]) > max_columns:
        add_text_paragraph(
            document,
            f"Word 报告仅展示前 {max_columns} 列，完整结果见对应 CSV/XLSX 文件。",
        )


def read_csv_rows(path: Path) -> list[list[str]]:
    with path.open("r", encoding="utf-8-sig", newline="") as handle:
        return [[str(value) for value in row] for row in csv.reader(handle)]


def evidence_index(results: dict[str, Any]) -> dict[str, dict[str, str]]:
    index: dict[str, dict[str, str]] = {}
    for module_id, result in results.items():
        for table in result.get("tables", []):
            table_id = str(table.get("table_id") or "")
            if table_id:
                index[f"{module_id}:{table_id}"] = {
                    "type": "table",
                    "title": str(table.get("title") or table_id),
                    "path": str(table.get("xlsx_path") or table.get("csv_path") or ""),
                }
        for figure in result.get("figures", []):
            figure_id = str(figure.get("figure_id") or "")
            if figure_id:
                index[f"{module_id}:{figure_id}"] = {
                    "type": "figure",
                    "title": str(figure.get("title") or figure_id),
                    "path": str(figure.get("path") or ""),
                }
    return index


def build_claim_rows(
    manuscript: dict[str, Any], results: dict[str, Any]
) -> list[dict[str, str]]:
    index = evidence_index(results)
    rows: list[dict[str, str]] = []
    for claim in manuscript.get("claims") or []:
        references = [str(item) for item in claim.get("evidence_refs") or []]
        unresolved = [item for item in references if item not in index]
        if unresolved:
            raise SystemExit(
                "论文主张包含未解析的证据引用：" + "、".join(unresolved)
            )
        evidence = [
            f"{index[item]['title']}（{index[item]['path']}）"
            for item in references
        ]
        rows.append(
            {
                "claim_id": str(claim.get("id") or ""),
                "statement": str(claim.get("statement") or ""),
                "evidence_refs": "；".join(references),
                "evidence_files": "；".join(evidence),
                "interpretation_level": str(
                    claim.get("interpretation_level") or ""
                ),
                "boundary": str(claim.get("boundary") or ""),
                "status": "confirmed_and_resolved",
            }
        )
    return rows


def write_manuscript_support_artifacts(
    run_dir: Path,
    plan: dict[str, Any],
    manifest: dict[str, Any],
    results: dict[str, Any],
) -> list[dict[str, str]]:
    reporting = plan.get("reporting") or {}
    manuscript = reporting.get("manuscript_support") or {}
    if manuscript.get("enabled") is not True:
        return []
    output_dir = run_dir / "90_最终报告"
    output_dir.mkdir(parents=True, exist_ok=True)
    rows = build_claim_rows(manuscript, results)

    claim_path = output_dir / "02_主张证据边界表.csv"
    fieldnames = [
        "claim_id",
        "statement",
        "evidence_refs",
        "evidence_files",
        "interpretation_level",
        "boundary",
        "status",
    ]
    with claim_path.open("w", encoding="utf-8-sig", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)

    variables = plan.get("variables") or {}
    labels = variables.get("labels") or {}
    units = variables.get("units") or {}
    manual_terms = manuscript.get("terminology") or {}
    term_names = sorted(set(labels) | set(units) | set(manual_terms))
    terms: dict[str, Any] = {}
    for term in term_names:
        manual_value = manual_terms.get(term)
        if isinstance(manual_value, dict):
            entry = dict(manual_value)
        else:
            entry = {
                "preferred_term": str(
                    manual_value or labels.get(term) or term
                )
            }
        if labels.get(term):
            entry.setdefault("label", str(labels[term]))
        if units.get(term):
            entry.setdefault("unit", str(units[term]))
        entry.setdefault("source_variable", term)
        terms[term] = entry
    terminology_payload = {
        "schema_version": "1.0",
        "run_id": manifest.get("run_id"),
        "terms": terms,
        "rule": "同一术语、缩写、单位和变量标签在本次运行的全部报告中保持一致。",
    }
    terminology_path = output_dir / "04_术语账本.yml"
    terminology_path.write_text(
        yaml.safe_dump(
            terminology_payload,
            allow_unicode=True,
            sort_keys=False,
        ),
        encoding="utf-8",
    )

    research = plan.get("research") or {}
    handling = plan.get("data_handling") or {}
    runtime = plan.get("runtime") or {}
    modules = [
        item if isinstance(item, str) else item.get("id", "")
        for item in (plan.get("analysis") or {}).get("modules", [])
    ]
    methods_lines = [
        "# 统计方法与可复现性摘要",
        "",
        f"- 运行编号：{manifest.get('run_id', '')}",
        f"- 主要研究问题：{research.get('primary_question', '')}",
        f"- 研究设计：{research.get('design', 'unknown')}",
        f"- 目标量/研究目标：{research.get('estimand_or_target', '') or '未单独登记'}",
        f"- 已确认模块：{', '.join(str(item) for item in modules if item)}",
        f"- 缺失值策略：{handling.get('missing_strategy', '')}",
        (
            "- 多重比较："
            f"{(handling.get('multiple_testing') or {}).get('method', '')}；"
            f"比较族={(handling.get('multiple_testing') or {}).get('family_definition', '')}"
        ),
        f"- 统计引擎：{runtime.get('language', 'R')}",
        f"- 最低 R 版本：{runtime.get('minimum_version', '')}",
        f"- 随机种子：{(plan.get('run') or {}).get('random_seed', '')}",
        f"- 分析方案 SHA-256：{manifest.get('analysis_plan_sha256', '')}",
        "- R 会话信息：sessionInfo.txt",
        "- 包版本：package_versions.csv",
        "- 输入文件与全部输出哈希：manifest.json",
        "",
        "## 表述边界",
        "",
        "- 结果陈述、解释和边界分别登记，不以 P 值替代效应量、区间或诊断。",
        "- 关联和预测结果不得自动升级为因果结论。",
        "- 未登记或未解析到统一结果对象的证据不得写入确认主张。",
    ]
    methods_path = output_dir / "03_统计方法与可复现性.md"
    methods_path.write_text("\n".join(methods_lines) + "\n", encoding="utf-8")
    return rows


def write_academic_reporting_audit(
    run_dir: Path, plan: dict[str, Any], results: dict[str, Any]
) -> Path:
    """Record the evidence/boundary checks applied to report prose without inventing claims."""
    output_dir = run_dir / "90_最终报告"
    output_dir.mkdir(parents=True, exist_ok=True)
    manuscript = ((plan.get("reporting") or {}).get("manuscript_support") or {})
    lines = [
        "# 学术报告表述审计",
        "",
        "本文件仅审计本次自动报告的证据边界，不生成未确认的论文结论。",
        "",
        "## 已执行的约束",
        "",
        "- 结果章节只消费同一运行的统一结果对象。",
        "- 关联、预测与因果解释层级不互相替代。",
        "- 效应量、区间、P 值、诊断与局限性保留在其对应表格或模块对象中。",
        "- 未登记的样本量、统计结果、机制或外部可推广性不被补写。",
        "",
        "## 模块证据登记",
        "",
    ]
    for module_id, result in results.items():
        lines.append(
            f"- `{module_id}`：表格 {len(result.get('tables', []))} 个，"
            f"图形 {len(result.get('figures', []))} 个，"
            f"诊断 {len(result.get('diagnostics', []))} 项，"
            f"局限性 {len(result.get('limitations', []))} 项。"
        )
    lines.extend(["", "## 论文级主张", ""])
    if manuscript.get("enabled") is True:
        lines.append("- 已启用：只接受方案中预先确认且可解析到结果对象的主张；详见 `02_主张证据边界表.csv`。")
    else:
        lines.append("- 未启用：本报告不自动从统计显著性、模型方向或图形生成论文级主张。")
    path = output_dir / "05_学术报告表述审计.md"
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="生成简要医学统计分析 Word 报告。")
    parser.add_argument("--run-dir", required=True)
    parser.add_argument("--output")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    run_dir = Path(args.run_dir).expanduser().resolve()
    output_path = (
        Path(args.output).expanduser().resolve()
        if args.output
        else run_dir / "90_最终报告" / "01_医学统计分析简要报告.docx"
    )
    try:
        output_path.relative_to(run_dir)
    except ValueError as exc:
        raise SystemExit("报告必须保存在当前运行目录内。") from exc

    validation_path = run_dir / "validation_report.json"
    required = [
        validation_path,
        run_dir / "manifest.json",
        run_dir / "analysis_plan.yml",
        run_dir / "data_profile.json",
        run_dir / "execution_status.json",
        run_dir / "analysis_results.json",
    ]
    missing = [path.name for path in required if not path.exists()]
    if missing:
        raise SystemExit(f"缺少生成报告所需文件：{', '.join(missing)}")
    validation = load_json(validation_path)
    if validation.get("valid") is not True or validation.get("mode") not in {
        "execute",
        "report",
    }:
        raise SystemExit("必须先通过 execute 或 report 模式输出验证。")

    manifest = load_json(run_dir / "manifest.json")
    plan = load_yaml(run_dir / "analysis_plan.yml")
    profile = load_json(run_dir / "data_profile.json")
    execution = load_json(run_dir / "execution_status.json")
    results = load_json(run_dir / "analysis_results.json")
    if execution.get("status") != "completed":
        raise SystemExit("分析执行状态不是 completed。")
    manuscript_claim_rows = write_manuscript_support_artifacts(
        run_dir, plan, manifest, results
    )
    write_academic_reporting_audit(run_dir, plan, results)

    document = Document()
    section = document.sections[0]
    section.page_width = Cm(21)
    section.page_height = Cm(29.7)
    section.top_margin = Cm(2.54)
    section.bottom_margin = Cm(2.54)
    section.left_margin = Cm(2.54)
    section.right_margin = Cm(2.54)
    section.header_distance = Cm(1.25)
    section.footer_distance = Cm(1.25)

    normal_style = document.styles["Normal"]
    normal_style.font.name = LATIN_FONT
    normal_style.font.size = Pt(BODY_SIZE)
    normal_style._element.rPr.rFonts.set(qn("w:ascii"), LATIN_FONT)
    normal_style._element.rPr.rFonts.set(qn("w:hAnsi"), LATIN_FONT)
    normal_style._element.rPr.rFonts.set(qn("w:eastAsia"), EAST_ASIA_FONT)
    normal_style.paragraph_format.line_spacing = 1.5
    normal_style.paragraph_format.first_line_indent = Pt(24)
    normal_style.paragraph_format.space_before = Pt(0)
    normal_style.paragraph_format.space_after = Pt(0)

    title = document.add_paragraph()
    set_paragraph_format(
        title,
        indent=False,
        alignment=WD_ALIGN_PARAGRAPH.CENTER,
        space_after=6,
    )
    title_run = title.add_run("医学统计分析简要报告")
    set_run_font(title_run, size=16, bold=True)
    add_text_paragraph(
        document,
        f"运行编号：{manifest.get('run_id', '')}；生成时间：{utc_now()}",
        indent=False,
    )

    add_heading(document, "一、研究问题与分析方案", 1)
    research = plan.get("research") or {}
    add_text_paragraph(document, str(research.get("primary_question") or "未提供主要研究问题。"))
    add_text_paragraph(
        document,
        f"研究设计：{research.get('design', 'unknown')}。本次执行模块："
        + "、".join(execution.get("completed_modules", []))
        + "。",
    )

    add_heading(document, "二、数据概况与质量", 1)
    summary = profile.get("summary") or {}
    add_text_paragraph(
        document,
        "本次共盘点 "
        f"{summary.get('file_count', 0)} 个文件，成功探查 "
        f"{summary.get('profiled_dataset_count', 0)} 个数据集；"
        f"累计记录数为 {summary.get('total_rows_across_datasets', 0)}，"
        f"变量数为 {summary.get('total_variables_across_datasets', 0)}，"
        f"总体缺失比例为 {summary.get('overall_missing_pct', 'NA')}%。",
    )
    for warning in profile.get("warnings", []):
        add_text_paragraph(document, str(warning), bold_prefix="数据质量提示：")

    add_heading(document, "三、统计结果", 1)
    module_counter = 1
    for module_id, result in results.items():
        add_heading(
            document,
            f"3.{module_counter} {MODULE_TITLES.get(module_id, module_id)}",
            2,
        )
        module_counter += 1
        for narrative in result.get("narrative", []):
            add_text_paragraph(document, str(narrative))
        for table in result.get("tables", []):
            add_heading(document, str(table.get("title", table.get("table_id", "结果表"))), 2)
            csv_path = run_dir / str(table["csv_path"])
            add_three_line_table(document, read_csv_rows(csv_path))
            for footnote in table.get("footnotes", []):
                add_text_paragraph(document, f"注：{footnote}", indent=False)
        for figure in result.get("figures", []):
            figure_path = run_dir / str(figure.get("path", ""))
            if figure_path.is_file():
                paragraph = document.add_paragraph()
                set_paragraph_format(paragraph, indent=False, alignment=WD_ALIGN_PARAGRAPH.CENTER)
                run = paragraph.add_run()
                figure_title = str(figure.get("title", "统计图"))
                inline_shape = run.add_picture(str(figure_path), width=Inches(5.8))
                inline_shape._inline.docPr.set("descr", figure_title)
                inline_shape._inline.docPr.set("title", figure_title)
                caption = document.add_paragraph()
                set_paragraph_format(caption, indent=False, alignment=WD_ALIGN_PARAGRAPH.CENTER)
                caption_run = caption.add_run(figure_title)
                set_run_font(caption_run, size=10)
                statistics = figure.get("statistics") or {}
                caption_details = [
                    str(figure.get("conclusion") or ""),
                    f"n：{statistics.get('n_definition', '')}",
                    f"中心统计量：{statistics.get('center_statistic', '')}",
                    f"区间/误差：{statistics.get('interval', '')}",
                    f"检验：{statistics.get('test', '')}",
                    (
                        "多重比较校正："
                        f"{statistics.get('multiple_comparison_correction', '')}"
                    ),
                ]
                detail_paragraph = document.add_paragraph()
                set_paragraph_format(
                    detail_paragraph,
                    indent=False,
                    alignment=WD_ALIGN_PARAGRAPH.LEFT,
                )
                detail_run = detail_paragraph.add_run(
                    "；".join(item for item in caption_details if item)
                )
                set_run_font(detail_run, size=10)

    if manuscript_claim_rows:
        add_heading(document, "四、经确认的主张、证据与边界", 1)
        add_text_paragraph(
            document,
            "本节只列出分析方案中由用户确认、且已解析到同一运行统一结果对象的主张。"
            "结果陈述、解释层级和适用边界不得互相替代。",
        )
        claim_table_rows = [[
            "主张编号",
            "主张",
            "证据对象",
            "解释层级",
            "边界",
        ]]
        claim_table_rows.extend([
            [
                row["claim_id"],
                row["statement"],
                row["evidence_files"],
                row["interpretation_level"],
                row["boundary"],
            ]
            for row in manuscript_claim_rows
        ])
        add_three_line_table(
            document,
            claim_table_rows,
            max_rows=25,
            max_columns=5,
        )

    diagnostics_number = "五" if manuscript_claim_rows else "四"
    reproducibility_number = "六" if manuscript_claim_rows else "五"
    add_heading(document, f"{diagnostics_number}、诊断、警告与局限性", 1)
    any_notes = False
    for result in results.values():
        for warning in result.get("warnings", []):
            any_notes = True
            add_text_paragraph(document, str(warning), bold_prefix="警告：")
        for limitation in result.get("limitations", []):
            any_notes = True
            add_text_paragraph(document, str(limitation), bold_prefix="局限性：")
    if not any_notes:
        add_text_paragraph(document, "统一结果对象未登记额外警告或局限性。")

    add_heading(document, f"{reproducibility_number}、可复现性信息", 1)
    add_text_paragraph(
        document,
        "本报告仅使用同一运行编号下经验证的统一结果对象生成。"
        f"分析方案指纹为 {manifest.get('analysis_plan_sha256', '')}；"
        "R 版本与包版本分别记录于 sessionInfo.txt 和 package_versions.csv；"
        "Python/R 双环境及锁定状态记录于 runtime/environment_manifest.json。",
    )

    output_path.parent.mkdir(parents=True, exist_ok=True)
    document.save(output_path)
    print(json.dumps({"status": "created", "output": str(output_path)}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
