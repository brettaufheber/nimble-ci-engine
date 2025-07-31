#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025 Eric Löffler <eric.loeffler@opalia.systems>
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

if [[ $# -ne 1 ]]; then
  log INFO 'Usage: %s "<number> <unit> [<number> <unit>] ..."' "${0##*/}"
  exit 1
fi

LC_NUMERIC=C awk \
  -v expr="$1" \
  '
    BEGIN {

      # trim expression part
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", expr)

      if (expr == "") {
        printf "Error: unexpected empty duration expression\n" > "/dev/stderr"
        exit 1
      }

      total = 0.0
      rest = expr

      while (rest != "") {

        if (!match(rest, /^[[:space:]]*([[:digit:]]+([.][[:digit:]]+)?)[[:blank:]]*([[:alpha:]]+)([[:space:]]+|$)/, m)) {
          print "Error: expected format <number> <unit> [<number> <unit>] ...\n" > "/dev/stderr"
          exit 1
        }

        value = strtonum(m[1])
        unit = tolower(m[3])
        factor = get_factor(unit)

        if (factor < 0) {
          printf "Error: unsupported unit %s\n", unit > "/dev/stderr"
          exit 1
        }

        total += value * factor
        rest = substr(rest, RSTART + RLENGTH)
      }

      seconds_int = int(total)
      rounded = (total - seconds_int > 1e-9) ? seconds_int + 1 : seconds_int
      print rounded
      exit 0
    }

    function get_factor(u) {

      if (u ~ /^(s|secs?|seconds?)$/)
        return 1

      if (u ~ /^(m|mins?|minutes?)$/)
        return 1 * 60

      if (u ~ /^(h|hrs?|hours?)$/)
        return 1 * 60 * 60

      if (u ~ /^(d|days?)$/)
        return 1 * 60 * 60 * 24

      if (u ~ /^(w|wks?|weeks?)$/)
        return 1 * 60 * 60 * 24 * 7

      return -1
    }
  '
