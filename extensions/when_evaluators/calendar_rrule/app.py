#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2025 Eric Löffler <eric.loeffler@opalia.systems>
# SPDX-License-Identifier: GPL-3.0-or-later

import sys
from pathlib import Path
from typing import Sequence

from dateutil import rrule
from lib_helpers import schedule_common


def unfold_and_strip_dtstart(expr: str) -> str:
    expr = expr.strip()
    # unfold physical to logical lines
    lines = []
    for line in expr.splitlines():
        if line == "":
            continue
        if line[0].isspace():
            lines[-1] += line.strip()
        else:
            lines.append(line.strip())
    # filter out DTSTART lines (case-insensitive)
    out = []
    for line in lines:
        if line.upper().startswith("DTSTART:") or line.upper().startswith("DTSTART;"):
            continue
        out.append(line)
    # create output with logical lines
    return "\n".join(out)


def main(argv: Sequence[str]) -> int:
    if len(argv) != 5:
        print(f"Usage: {Path(argv[0]).name} <EXPRESSION> <BASE_DATETIME> <TIMEZONE|null> <JITTER>", file=sys.stderr)
        return 1

    expr = argv[1]
    base_str = argv[2]
    tz_name = argv[3]
    jitter_spec = argv[4]

    try:
        base_dt = schedule_common.parse_dt_with_tz(base_str, tz_name)

        # enforce that DTSTART in the expression must NOT override application settings
        expr_clean = unfold_and_strip_dtstart(expr)

        ruleset = rrule.rrulestr(expr_clean, dtstart=base_dt, forceset=True)
        next_dt = ruleset.after(base_dt, inc=True)
        jitter = schedule_common.compute_jitter(jitter_spec)

        if next_dt is not None and next_dt.tzinfo is None:
            next_dt = next_dt.replace(tzinfo=base_dt.tzinfo)

        print(schedule_common.finalize_result(base_dt, next_dt, jitter))
        return 0

    except Exception as e:
        print(f"Error: Failed to compute next occurrence for RRULE expression \"{expr}\": {e}", file=sys.stderr)
        return 3


if __name__ == "__main__":
    sys.exit(main(sys.argv))
