#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2025 Eric Löffler <eric.loeffler@opalia.systems>
# SPDX-License-Identifier: GPL-3.0-or-later

import calendar
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional, Sequence

from lib_helpers import schedule_common


def systemd_analyze_calendar(expr: str, dt: datetime) -> Optional[datetime]:
    helper = Path(__file__).resolve().parent / "systemd_analyze_calendar.sh"
    dt_utc = dt.astimezone(timezone.utc)
    epoch_ms = calendar.timegm(dt_utc.utctimetuple()) * 1000 + dt_utc.microsecond // 1000
    tz_env = schedule_common.to_tz_env_string(dt)
    completed = subprocess.run(
        [str(helper), expr, str(epoch_ms), tz_env],
        check=True,
        stdout=subprocess.PIPE,
        stderr=None,
        text=True,
    )
    output = completed.stdout.strip()
    return schedule_common.parse_dt_with_tz(output, None) if output != "null" else None


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
        next_dt = systemd_analyze_calendar(expr, base_dt)
        jitter = schedule_common.compute_jitter(jitter_spec)

        print(schedule_common.finalize_result(base_dt, next_dt, jitter))
        return 0

    except Exception as e:
        print(f"Error: Failed to compute next occurrence for systemd calendar expression \"{expr}\": {e}",
              file=sys.stderr)
        return 3


if __name__ == "__main__":
    sys.exit(main(sys.argv))
