# SPDX-FileCopyrightText: 2025 Eric Löffler <eric.loeffler@opalia.systems>
# SPDX-License-Identifier: GPL-3.0-or-later

import json
import re
import secrets
import subprocess
from dataclasses import dataclass
from datetime import datetime, timezone, tzinfo, timedelta
from typing import Optional
from zoneinfo import ZoneInfo


def parse_dt_with_tz(td_str: str, tz_name: Optional[str]) -> datetime:
    # datetime.fromisoformat does not accept 'Z', so mapping to '+00:00' is needed
    dt = datetime.fromisoformat(re.sub(r'Z$', '+00:00', td_str))

    if tz_name and tz_name != "null":
        target_tz = ZoneInfo(tz_name)

        # if no offset is present, use target_tz
        if dt.tzinfo is None:
            return dt.replace(tzinfo=target_tz)

        # convert to desired time zone
        return dt.astimezone(target_tz)

    # if no offset is present, interpret as UTC
    if dt.tzinfo is None:
        return dt.replace(tzinfo=timezone.utc)

    return dt


def to_tz_env_string(dt: datetime) -> str:
    tz: Optional[tzinfo] = dt.tzinfo

    if tz is None:
        return "UTC"

    if isinstance(tz, ZoneInfo):
        return tz.key

    off: Optional[timedelta] = dt.utcoffset()

    if off is None:
        return "UTC"

    total_minutes = int(off.total_seconds() // 60)

    # POSIX: local = UTC - offset -> invert sign
    sign = "-" if total_minutes >= 0 else "+"
    total_minutes = abs(total_minutes)

    hh, mm = divmod(total_minutes, 60)

    return f"UTC{sign}{hh}" if mm == 0 else f"UTC{sign}{hh}:{mm:02d}"


def duration2seconds(spec: str) -> int:
    completed = subprocess.run(
        ["duration2seconds", spec],
        check=True,
        stdout=subprocess.PIPE,
        stderr=None,
        text=True,
    )
    out = completed.stdout.strip()
    return int(out)


@dataclass(frozen=True)
class Jitter:
    max_s: int
    offset_s: int

    @property
    def is_active(self) -> bool:
        return self.max_s > 0


def compute_jitter(jitter_spec: str) -> Jitter:
    total = duration2seconds(jitter_spec)
    if total > 0:
        offset = secrets.randbelow(total + 1)
    else:
        offset = 0
    return Jitter(max_s=total, offset_s=offset)


def finalize_result(base_local: datetime, next_local: Optional[datetime], jitter: Jitter) -> str:
    base_epoch_s = int(base_local.astimezone(timezone.utc).timestamp())
    next_epoch_s = None

    if next_local is not None:
        next_epoch_s = int(next_local.astimezone(timezone.utc).timestamp())
        if jitter.is_active:
            next_epoch_s += jitter.offset_s

    result = {
        "base_epoch_s": base_epoch_s,
        "next_epoch_s": next_epoch_s,
        "jitter_s": jitter.max_s,
        "jitter_offset_s": jitter.offset_s,
        "delta_s": (base_epoch_s - next_epoch_s) if (next_epoch_s is not None) else None
    }

    return json.dumps(result, ensure_ascii=False, separators=(",", ":"))
