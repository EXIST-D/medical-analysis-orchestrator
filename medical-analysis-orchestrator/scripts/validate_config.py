#!/usr/bin/env python3
"""Validate the analysis configuration and approval gate."""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
from pathlib import Path
from typing import Any

try:
    import yaml
except ImportError:
    yaml = None


ALLOWED_MODES = {"inspect", "recommend", "confirm", "execute", "report"}
ALLOWED_AUTO_ACTIONS = {
    "copy_to_run",
    "normalize_column_names",
    "disambiguate_duplicate_column_names",
    "write_utf8_csv",
}
ALLOWED_FIGURE_PROFILES = {"analysis", "manuscript"}
ALLOWED_FIGURE_FORMATS = {"png", "svg", "pdf", "tiff"}
MANUSCRIPT_FIGURE_FORMATS = {"png", "svg", "pdf", "tiff"}
ALLOWED_INTERPRETATION_LEVELS = {
    "descriptive",
    "association",
    "prediction",
    "causal",
}


def load_structured(path: Path) -> dict[str, Any]:
    text = path.read_text(encoding="utf-8-sig")
    if yaml is not None:
        payload = yaml.safe_load(text)
    else:
        payload = json.loads(text)
    if not isinstance(payload, dict):
        raise ValueError("Configuration root must be a mapping")
    return payload


def plan_fingerprint(config: dict[str, Any]) -> str:
    normalized = copy.deepcopy(config)
    normalized.pop("approval", None)
    canonical = json.dumps(
        normalized,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    )
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def nested_get(payload: dict[str, Any], path: str) -> Any:
    current: Any = payload
    for key in path.split("."):
        if not isinstance(current, dict) or key not in current:
            return None
        current = current[key]
    return current


def module_ids(config: dict[str, Any]) -> list[str]:
    modules = nested_get(config, "analysis.modules") or []
    result = []
    for item in modules:
        if isinstance(item, str):
            result.append(item)
        elif isinstance(item, dict) and item.get("id"):
            result.append(str(item["id"]))
    return result


def validate_reporting_contract(
    config: dict[str, Any], errors: list[str], warnings: list[str]
) -> None:
    reporting = config.get("reporting") or {}
    figure_contract = reporting.get("figure_contract") or {}
    profile = str(figure_contract.get("profile") or "analysis").lower()
    backend = str(figure_contract.get("backend") or "R")
    formats_value = figure_contract.get("formats")
    if formats_value is None:
        formats_value = reporting.get("figure_formats") or ["png"]
    formats = [
        str(item).lower()
        for item in formats_value
        if isinstance(item, (str, int, float))
    ] if isinstance(formats_value, list) else []

    if profile not in ALLOWED_FIGURE_PROFILES:
        errors.append(
            "reporting.figure_contract.profile must be analysis or manuscript"
        )
    if backend.upper() != "R":
        errors.append(
            "reporting.figure_contract.backend must be R; statistical figures "
            "cannot be redrawn by another backend"
        )
    if not formats:
        errors.append("reporting.figure_contract.formats must not be empty")
    unsupported = sorted(set(formats) - ALLOWED_FIGURE_FORMATS)
    if unsupported:
        errors.append(
            "Unsupported reporting.figure_contract formats: "
            + ", ".join(unsupported)
        )
    if len(formats) != len(set(formats)):
        errors.append("reporting.figure_contract.formats contains duplicates")
    dimension_defaults = {"width_mm": 183, "height_mm": 120}
    for dimension, default_value in dimension_defaults.items():
        value = figure_contract.get(dimension, default_value)
        if not isinstance(value, (int, float)) or value <= 0:
            errors.append(
                f"reporting.figure_contract.{dimension} must be positive"
            )
    dpi = figure_contract.get("dpi", 300)
    if not isinstance(dpi, int) or dpi < 150:
        errors.append("reporting.figure_contract.dpi must be an integer >= 150")
    for flag in ("require_source_data", "require_statistics_metadata"):
        if figure_contract.get(flag, True) is not True:
            errors.append(
                f"reporting.figure_contract.{flag} must be true"
            )

    if profile == "manuscript":
        missing_formats = sorted(MANUSCRIPT_FIGURE_FORMATS - set(formats))
        if missing_formats:
            errors.append(
                "Manuscript figure profile requires png, svg, pdf and tiff; "
                "missing: " + ", ".join(missing_formats)
            )
        if not isinstance(dpi, int) or dpi < 300:
            errors.append(
                "Manuscript figure profile requires dpi >= 300"
            )
        if figure_contract.get("require_source_data") is not True:
            errors.append(
                "Manuscript figure profile requires source data"
            )
        if figure_contract.get("require_statistics_metadata") is not True:
            errors.append(
                "Manuscript figure profile requires statistics metadata"
            )
        if figure_contract.get("require_editable_text") is not True:
            errors.append(
                "Manuscript figure profile requires editable text in vector exports"
            )

    manuscript = reporting.get("manuscript_support") or {}
    if manuscript.get("enabled") is not True:
        return
    for flag in (
        "separate_results_and_interpretation",
        "include_methods_reproducibility",
        "build_terminology_ledger",
    ):
        if manuscript.get(flag) is not True:
            errors.append(
                f"reporting.manuscript_support.{flag} must be true when enabled"
            )
    terminology = manuscript.get("terminology")
    if not isinstance(terminology, dict):
        errors.append(
            "reporting.manuscript_support.terminology must be a mapping"
        )
    claims = manuscript.get("claims")
    if not isinstance(claims, list) or not claims:
        errors.append(
            "reporting.manuscript_support.claims must contain at least one "
            "user-confirmed claim"
        )
        return
    claim_ids: list[str] = []
    for index, claim in enumerate(claims, start=1):
        label = f"reporting.manuscript_support.claims[{index}]"
        if not isinstance(claim, dict):
            errors.append(f"{label} must be a mapping")
            continue
        claim_id = str(claim.get("id") or "").strip()
        if not claim_id:
            errors.append(f"{label}.id is required")
        else:
            claim_ids.append(claim_id)
        if not str(claim.get("statement") or "").strip():
            errors.append(f"{label}.statement is required")
        evidence_refs = claim.get("evidence_refs")
        if (
            not isinstance(evidence_refs, list)
            or not evidence_refs
            or any(not str(item).strip() for item in evidence_refs)
        ):
            errors.append(f"{label}.evidence_refs must contain stable references")
        if not str(claim.get("boundary") or "").strip():
            errors.append(f"{label}.boundary is required")
        interpretation_level = str(
            claim.get("interpretation_level") or ""
        ).lower()
        if interpretation_level not in ALLOWED_INTERPRETATION_LEVELS:
            errors.append(
                f"{label}.interpretation_level must be one of "
                f"{sorted(ALLOWED_INTERPRETATION_LEVELS)}"
            )
        if (
            interpretation_level == "causal"
            and not str(
                nested_get(config, "research.estimand_or_target") or ""
            ).strip()
        ):
            warnings.append(
                f"{label} is causal but research.estimand_or_target is empty"
            )
    if len(claim_ids) != len(set(claim_ids)):
        errors.append(
            "reporting.manuscript_support claim IDs must be unique"
        )


def validate(
    config: dict[str, Any], config_path: Path, skill_root: Path, forced_mode: str | None
) -> dict[str, Any]:
    errors: list[str] = []
    warnings: list[str] = []
    mode = forced_mode or nested_get(config, "run.mode") or "inspect"
    fingerprint = plan_fingerprint(config)

    if mode not in ALLOWED_MODES:
        errors.append(f"run.mode must be one of {sorted(ALLOWED_MODES)}")
    if nested_get(config, "input.read_only") is not True:
        errors.append("input.read_only must be true")
    seed = nested_get(config, "run.random_seed")
    if not isinstance(seed, int) or seed <= 0:
        errors.append("run.random_seed must be a positive integer")

    input_value = nested_get(config, "input.path")
    if input_value:
        input_path = Path(str(input_value)).expanduser()
        if not input_path.is_absolute():
            input_path = (config_path.parent / input_path).resolve()
        if not input_path.exists():
            errors.append(f"input.path does not exist: {input_path}")
        if mode in {"execute", "report"} and not input_path.is_file():
            errors.append("input.path must identify one file before execution")
    elif mode in {"inspect", "execute", "report"}:
        errors.append("input.path is required")

    selected_modules = module_ids(config)
    if len(selected_modules) != len(set(selected_modules)):
        errors.append("analysis.modules contains duplicate module IDs")
    registered_modules: dict[str, dict[str, Any]] = {}
    registry_path = skill_root / "modules" / "registry.yml"
    try:
        registry = load_structured(registry_path)
        registered_modules = {
            str(item["id"]): item
            for item in registry.get("modules", [])
            if isinstance(item, dict) and item.get("id")
        }
    except Exception as exc:
        errors.append(f"Cannot read module registry: {exc}")
    module_status: dict[str, str] = {}
    for module_id in selected_modules:
        registry_entry = registered_modules.get(module_id)
        if registry_entry is None:
            errors.append(f"Unregistered module: {module_id}")
        descriptor = skill_root / "modules" / module_id / "module.yml"
        if not descriptor.exists():
            errors.append(f"Unknown module: {module_id}")
            continue
        try:
            module_config = load_structured(descriptor)
            status = str(module_config.get("status", "unknown"))
            module_status[module_id] = status
            if (
                registry_entry is not None
                and str(registry_entry.get("status")) != status
            ):
                errors.append(
                    f"Module registry status mismatch for '{module_id}'"
                )
            if mode == "execute" and status != "ready":
                errors.append(
                    f"Module '{module_id}' has status '{status}', not 'ready'"
                )
            if mode == "execute":
                for required_path in module_config.get("required_config", []):
                    value = nested_get(config, str(required_path))
                    if value is None or value == "" or value == []:
                        errors.append(
                            f"Module '{module_id}' requires config field '{required_path}'"
                        )
        except Exception as exc:
            errors.append(f"Cannot read module descriptor {module_id}: {exc}")

    if "survival" in selected_modules:
        if not nested_get(config, "variables.time"):
            errors.append("Survival analysis requires variables.time")
        if not nested_get(config, "variables.event"):
            errors.append("Survival analysis requires variables.event")
    if "reliability-validity" in selected_modules:
        scales = nested_get(
            config, "analysis.parameters.reliability-validity.scales"
        )
        if not isinstance(scales, dict) or not scales:
            errors.append(
                "Reliability/validity analysis requires at least one named scale"
            )
        elif any(
            not isinstance(items, list) or len(items) < 3
            for items in scales.values()
        ):
            errors.append(
                "Each reliability/validity scale requires at least three items"
            )
    if "factor-analysis" in selected_modules:
        factor_params = nested_get(
            config, "analysis.parameters.factor-analysis"
        ) or {}
        factor_items = factor_params.get("items") or []
        efa = factor_params.get("efa") or {}
        cfa = factor_params.get("cfa") or {}
        if len(factor_items) < 3:
            errors.append("Factor analysis requires at least three items")
        if not efa.get("enabled") and not cfa.get("enabled"):
            errors.append("Factor analysis requires EFA and/or CFA to be enabled")
        if efa.get("enabled"):
            factors = efa.get("factors")
            if not isinstance(factors, int) or factors < 1:
                errors.append(
                    "Confirmed EFA requires a positive integer factor count"
                )
        if cfa.get("enabled") and not str(cfa.get("model") or "").strip():
            errors.append("Confirmed CFA requires explicit lavaan model syntax")
    if "mixed-effects" in selected_modules:
        mixed_params = nested_get(
            config, "analysis.parameters.mixed-effects"
        ) or {}
        if not mixed_params.get("outcome"):
            errors.append("Mixed-effects analysis requires an outcome")
        if not mixed_params.get("fixed_effects"):
            errors.append("Mixed-effects analysis requires fixed effects")
        if not mixed_params.get("group"):
            errors.append("Mixed-effects analysis requires a grouping variable")
        if (
            str(mixed_params.get("family") or "gaussian").lower() == "binomial"
            and mixed_params.get("event_level") in {None, ""}
        ):
            errors.append(
                "Binomial mixed-effects analysis requires event_level"
            )

    validate_reporting_contract(config, errors, warnings)

    approval = config.get("approval") or {}
    if mode in {"execute", "report"}:
        data_handling = config.get("data_handling") or {}
        auto_actions = set(data_handling.get("auto_actions") or [])
        unapproved_auto_actions = sorted(auto_actions - ALLOWED_AUTO_ACTIONS)
        if unapproved_auto_actions:
            errors.append(
                "data_handling.auto_actions contains actions that require confirmation: "
                + ", ".join(unapproved_auto_actions)
            )
        action_ids: list[str] = []
        for action in data_handling.get("confirmed_actions") or []:
            if not isinstance(action, dict):
                errors.append("Each confirmed cleaning action must be a mapping")
                continue
            action_id = str(action.get("id") or "")
            if not action_id:
                errors.append("Each confirmed cleaning action requires a stable id")
            else:
                action_ids.append(action_id)
            for field in ("action", "confirmed_by", "confirmed_at", "reason"):
                if not action.get(field):
                    errors.append(
                        f"Confirmed cleaning action '{action_id or '<unknown>'}' "
                        f"requires '{field}'"
                    )
        if len(action_ids) != len(set(action_ids)):
            errors.append("Confirmed cleaning action IDs must be unique")
        if data_handling.get("missing_strategy") in {None, "", "undecided"}:
            errors.append("data_handling.missing_strategy must be confirmed")
        if approval.get("confirmed") is not True:
            errors.append("approval.confirmed must be true before execution")
        for field in ("confirmed_by", "confirmed_at", "plan_sha256"):
            if not approval.get(field):
                errors.append(f"approval.{field} is required before execution")
        if config.get("decisions_required"):
            errors.append("decisions_required must be empty before execution")
        if not nested_get(config, "research.primary_question"):
            errors.append("research.primary_question is required before execution")
        if not nested_get(config, "input.expected_sha256"):
            errors.append("input.expected_sha256 is required before execution")
        if not nested_get(config, "variables.outcomes.primary"):
            warnings.append(
                "No primary outcome is selected; only modules that do not require one may run"
            )
        expected = approval.get("plan_sha256")
        if expected and expected != fingerprint:
            errors.append(
                "approval.plan_sha256 does not match the current plan; reconfirm the plan"
            )
        if not selected_modules:
            errors.append("analysis.modules must contain at least one confirmed module")
        if nested_get(config, "runtime.language") != "R":
            errors.append("Current version supports R as the analysis engine only")

    return {
        "valid": not errors,
        "mode": mode,
        "plan_sha256": fingerprint,
        "module_status": module_status,
        "errors": errors,
        "warnings": warnings,
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Validate an analysis plan.")
    parser.add_argument("config", help="analysis_plan.yml")
    parser.add_argument(
        "--mode",
        choices=sorted(ALLOWED_MODES),
        help="Override run.mode for validation",
    )
    parser.add_argument(
        "--skill-root",
        help="Skill root; defaults to the parent of this scripts directory",
    )
    parser.add_argument("--output", help="Optional JSON validation report")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    config_path = Path(args.config).expanduser().resolve()
    skill_root = (
        Path(args.skill_root).expanduser().resolve()
        if args.skill_root
        else Path(__file__).resolve().parent.parent
    )
    try:
        config = load_structured(config_path)
        result = validate(config, config_path, skill_root, args.mode)
    except Exception as exc:
        result = {
            "valid": False,
            "mode": args.mode,
            "plan_sha256": None,
            "module_status": {},
            "errors": [f"{type(exc).__name__}: {exc}"],
            "warnings": [],
        }
    text = json.dumps(result, ensure_ascii=False, indent=2)
    if args.output:
        output_path = Path(args.output).expanduser().resolve()
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(text, encoding="utf-8")
    print(text)
    return 0 if result["valid"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
