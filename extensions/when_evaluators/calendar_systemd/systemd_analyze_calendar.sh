#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025 Eric Löffler <eric.loeffler@opalia.systems>
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

if ! command -v systemd-analyze &> /dev/null; then
  log ERROR 'Required command systemd-analyze is not installed'
  exit 2
fi

if [[ $# -ne 3 ]]; then
  log WARNING 'Usage: %s <EXPRESSION> <BASE_EPOCH_MS> <TIMEZONE>' "${0##*/}"
  exit 1
fi

EXPRESSION="$1"
BASE_EPOCH_MS="$2"  # millisecond resolution
TIMEZONE="$3"

# simulate inclusive evaluation ( -1us)
BASE_EPOCH_US=$(( BASE_EPOCH_MS * 1000 ))
SECS=$(( (BASE_EPOCH_US - 1) / (1000 * 1000) ))
USECS=$(( (BASE_EPOCH_US - 1) % (1000 * 1000) ))
USECS="$(printf '%06d' "$USECS")"

NEXT_ELAPSE="$(
  LC_ALL=C TZ="$TIMEZONE" systemd-analyze calendar --iterations=1 --base-time="@$SECS.$USECS" "$EXPRESSION" |
    sed -n 's/^[[:space:]]*Next elapse:[[:space:]]*//p' |
    head -n1
)"

if [[ -z "$NEXT_ELAPSE" || $NEXT_ELAPSE == 'never' ]]; then
  printf 'null\n'
else
  TZ="$TIMEZONE" date -d "$NEXT_ELAPSE" -Iseconds
fi
