#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025 Eric Löffler <eric.loeffler@opalia.systems>
# SPDX-License-Identifier: GPL-3.0-or-later

# vals project page: https://github.com/helmfile/vals

set -euo pipefail

if ! command -v vals &> /dev/null; then
  log ERROR 'Required command vals is not installed'
  exit 2
fi

if [[ $# -ne 1 ]]; then
  log INFO 'Usage: %s <URI>' "${0##*/}"
  exit 1
fi

vals get "$1"
