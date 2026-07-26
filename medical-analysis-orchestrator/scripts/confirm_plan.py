#!/usr/bin/env python3
"""Record an explicit confirmation after all blocking decisions are resolved."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
from pathlib import Path

import yaml

from validate_config import plan_fingerprint


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="确认一份已解决全部决策项的分析方案。")
    parser.add_argument("config")
    parser.add_argument("--confirmed-by", required=True)
    parser.add_argument("--confirmed-at")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    path = Path(args.config).expanduser().resolve()
    config = yaml.safe_load(path.read_text(encoding="utf-8-sig"))
    if not isinstance(config, dict):
        raise SystemExit("分析方案根节点必须是映射。")
    if config.get("decisions_required"):
        raise SystemExit("仍有 decisions_required，不能确认执行。")
    config.setdefault("run", {})["mode"] = "execute"
    config["status"] = "confirmed"
    approval = config.setdefault("approval", {})
    approval["confirmed"] = True
    approval["confirmed_by"] = args.confirmed_by
    approval["confirmed_at"] = args.confirmed_at or datetime.now(timezone.utc).replace(
        microsecond=0
    ).isoformat()
    approval["plan_sha256"] = plan_fingerprint(config)
    path.write_text(
        yaml.safe_dump(config, allow_unicode=True, sort_keys=False),
        encoding="utf-8",
    )
    print(approval["plan_sha256"])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
