#!/usr/bin/env python3
"""Generate deterministic, fully synthetic datasets for examples and tests."""

from __future__ import annotations

import argparse
import math
import random
from pathlib import Path

import pandas as pd


SEED = 20260726


def logistic(value: float) -> float:
    return 1.0 / (1.0 + math.exp(-value))


def clinical_binary(rng: random.Random, rows: int = 240) -> pd.DataFrame:
    records = []
    for index in range(1, rows + 1):
        group = ["control", "intervention_a", "intervention_b"][(index - 1) % 3]
        sex = "female" if rng.random() < 0.52 else "male"
        smoker = "yes" if rng.random() < 0.27 else "no"
        age = round(rng.gauss(57, 11), 1)
        bmi = round(rng.gauss(24.5 + (0.8 if smoker == "yes" else 0), 3.2), 1)
        marker = round(rng.gauss(5.4 + 0.04 * (age - 57), 1.1), 2)
        baseline = round(rng.gauss(62 + 0.18 * (age - 57), 8.5), 1)
        group_effect = {"control": 0, "intervention_a": 4.2, "intervention_b": 6.5}[group]
        followup = round(
            18
            + 0.62 * baseline
            - 0.28 * age
            - 0.55 * bmi
            + group_effect
            + (1.8 if sex == "female" else 0)
            + rng.gauss(0, 5.2),
            1,
        )
        logit = (
            -2.0
            + 0.035 * (age - 55)
            + 0.10 * (bmi - 24)
            + 0.40 * (smoker == "yes")
            - 0.055 * (followup - 45)
            - 0.35 * (group == "intervention_b")
        )
        outcome = 1 if rng.random() < logistic(logit) else 0
        records.append(
            {
                "patient_id": f"SYN{index:04d}",
                "group": group,
                "sex": sex,
                "smoker": smoker,
                "age": age,
                "bmi": bmi,
                "marker": marker,
                "score_baseline": baseline,
                "score_followup": followup,
                "outcome": outcome,
            }
        )
    frame = pd.DataFrame(records)
    for row_index in (6, 37, 82, 141, 219):
        frame.loc[row_index, "marker"] = pd.NA
    for row_index in (18, 99, 177):
        frame.loc[row_index, "bmi"] = pd.NA
    return frame


def three_arm_trial(rng: random.Random, rows: int = 180) -> pd.DataFrame:
    records = []
    for index in range(1, rows + 1):
        arm = ["placebo", "dose_low", "dose_high"][(index - 1) % 3]
        baseline = round(rng.gauss(48, 7.5), 1)
        change = {"placebo": 0.8, "dose_low": 3.1, "dose_high": 5.3}[arm]
        records.append(
            {
                "subject_id": f"TRI{index:04d}",
                "arm": arm,
                "age": round(rng.gauss(51, 12), 1),
                "baseline_score": baseline,
                "week12_score": round(baseline + change + rng.gauss(0, 4.0), 1),
                "adverse_event": "yes"
                if rng.random() < {"placebo": 0.12, "dose_low": 0.18, "dose_high": 0.25}[arm]
                else "no",
            }
        )
    return pd.DataFrame(records)


def questionnaire(rng: random.Random, rows: int = 160) -> pd.DataFrame:
    records = []
    for index in range(1, rows + 1):
        latent = rng.gauss(0, 1)
        items = {
            f"item_{item}": max(
                1, min(5, round(3 + 0.75 * latent + rng.gauss(0, 0.8)))
            )
            for item in range(1, 9)
        }
        records.append(
            {
                "respondent_id": f"QUE{index:04d}",
                "group": "clinic" if index % 2 else "community",
                "age": round(rng.gauss(44, 13), 1),
                **items,
            }
        )
    return pd.DataFrame(records)


def longitudinal_trial(
    rng: random.Random, subjects: int = 90, visits: tuple[int, ...] = (0, 1, 2, 3)
) -> pd.DataFrame:
    records = []
    for subject_index in range(1, subjects + 1):
        treatment = "intervention" if subject_index % 2 == 0 else "control"
        sex = "female" if rng.random() < 0.52 else "male"
        age = round(rng.gauss(55, 10), 1)
        random_intercept = rng.gauss(0, 5.0)
        random_slope = rng.gauss(0, 0.75)
        for visit in visits:
            treatment_time_effect = 2.4 * visit if treatment == "intervention" else 0
            score = (
                52
                + 0.10 * (age - 55)
                + (1.2 if sex == "female" else 0)
                + 0.7 * visit
                + treatment_time_effect
                + random_intercept
                + random_slope * visit
                + rng.gauss(0, 2.8)
            )
            response_probability = logistic(
                -2.2
                + 0.65 * visit
                + 0.75 * (treatment == "intervention")
                + 0.30 * visit * (treatment == "intervention")
                + 0.08 * random_intercept
            )
            records.append(
                {
                    "subject_id": f"LNG{subject_index:04d}",
                    "treatment": treatment,
                    "sex": sex,
                    "age": age,
                    "visit": visit,
                    "score": round(score, 2),
                    "response": 1 if rng.random() < response_probability else 0,
                }
            )
    return pd.DataFrame(records)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="生成匿名医学分析示例数据。")
    parser.add_argument(
        "--output",
        required=True,
        help="Output directory for generated synthetic datasets.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    output_dir = Path(args.output).expanduser().resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    rng = random.Random(SEED)

    binary = clinical_binary(rng)
    trial = three_arm_trial(rng)
    scale = questionnaire(rng)
    longitudinal = longitudinal_trial(rng)
    binary.to_csv(output_dir / "01_匿名临床二分类结局.csv", index=False, encoding="utf-8-sig")
    trial.to_excel(output_dir / "02_匿名三组试验数据.xlsx", index=False)
    scale.to_csv(
        output_dir / "03_匿名问卷条目数据.dat",
        index=False,
        sep="\t",
        encoding="utf-8",
    )
    longitudinal.to_csv(
        output_dir / "04_匿名纵向重复测量数据.csv",
        index=False,
        encoding="utf-8-sig",
    )
    print(
        f"created={len(binary) + len(trial) + len(scale) + len(longitudinal)} rows; "
        f"output={output_dir}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
