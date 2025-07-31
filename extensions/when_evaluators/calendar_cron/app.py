#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2025 Eric Löffler <eric.loeffler@opalia.systems>
# SPDX-License-Identifier: GPL-3.0-or-later

import sys
from datetime import datetime
from pathlib import Path
from typing import Sequence

from croniter import croniter
from lib_helpers import schedule_common


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
        next_dt = croniter(expr, base_dt).get_next(datetime)
        jitter = schedule_common.compute_jitter(jitter_spec)

        print(schedule_common.finalize_result(base_dt, next_dt, jitter))
        return 0

    except Exception as e:
        print(f"Error: Failed to compute next occurrence for cron expression \"{expr}\": {e}", file=sys.stderr)
        return 3


if __name__ == "__main__":
    sys.exit(main(sys.argv))
