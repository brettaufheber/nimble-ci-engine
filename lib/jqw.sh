#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025 Eric Löffler <eric.loeffler@opalia.systems>
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

declare -a JQ_ARGS=()
ALLOW_YAML=0

if [[ -n "${JQ_MODULE_PATH:-}" ]]; then
  JQ_ARGS+=( -L "$JQ_MODULE_PATH" )
fi

while  [[ $# -ne 0 ]]; do
  case "$1" in
    --yaml)
      if ! command -v yq &> /dev/null; then
        log ERROR 'Required command yq is not installed (YAML wrapper for jq)'
        exit 2
      fi
      ALLOW_YAML=1
      shift 1
      ;;
    --yaml-optional)
      ALLOW_YAML=1
      shift 1
      ;;
    --argfile)
      VAR_NAME="$2"
      ARG_FILE="$3"
      shift 3
      if [[ ! -f "$ARG_FILE" ]]; then
        log ERROR 'File does not exist: %s' "$ARG_FILE"
        exit 1
      fi
      CONTENT="$(cat -- "$ARG_FILE")"
      JQ_ARGS+=( --argjson "$VAR_NAME" "$CONTENT" )
      ;;
    *)
      JQ_ARGS+=( "$1" )
      shift 1
      ;;
  esac
done

if (( ALLOW_YAML )) && command -v yq &> /dev/null; then
  exec yq "${JQ_ARGS[@]}"
else
  exec jq "${JQ_ARGS[@]}"
fi
