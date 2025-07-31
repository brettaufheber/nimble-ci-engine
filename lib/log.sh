#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025 Eric Löffler <eric.loeffler@opalia.systems>
# SPDX-License-Identifier: GPL-3.0-or-later

function main {

  ## global variables
  # LOG_LEVEL    # minimum level to log (DEBUG, INFO, WARNING, ERROR)
  # LOG_FILE     # optional file path to append logs

  local OPTS
  local THIS_LOG_LEVEL
  local MARKER_NAME
  local MARKER_VALUE
  local USE_STREAM
  local STDOUT
  local STDERR
  local LINE
  local -a CONTEXT_ARR
  local -A LOG_LEVELS

  # use original FDs if exported and still valid
  if [[ -n ${ORIG_OUT:-} && -n ${ORIG_ERR:-} ]] \
     && [[ -e "/proc/$$/fd/$ORIG_OUT" && -e "/proc/$$/fd/$ORIG_ERR" ]]; then
    exec 1>&"$ORIG_OUT" 2>&"$ORIG_ERR"
  fi

  USE_STREAM=0
  CONTEXT_ARR=()

  OPTS=$(
    getopt \
      -o 'l:f:m:sh' \
      -l 'log-level:,log-file:,marker:,stream,help' \
      -n "$(basename "$0")" -- "$@"
  )

  eval set -- "$OPTS"

  while true; do
    case "$1" in
      -l|--log-level)
        LOG_LEVEL="$2"
        shift 2
        ;;
      -f|--log-file)
        LOG_FILE="$2"
        shift 2
        ;;
      -m|--marker)
        IFS='=' read -r MARKER_NAME MARKER_VALUE <<< "$2"
        MARKER_VALUE="$(jq -R '.' <<< "$MARKER_VALUE")"
        CONTEXT_ARR+=("$MARKER_NAME=$MARKER_VALUE")
        shift 2
        ;;
      -s|--stream)
        USE_STREAM=1
        shift 1
        ;;
      -h|--help)
        print_usage
        exit 0
        ;;
      --)
        shift 1
        break
        ;;
      *)
        break
        ;;
    esac
  done

  LOG_LEVELS=([DEBUG]=0 [INFO]=1 [WARNING]=2 [ERROR]=3)
  LOG_LEVEL="${LOG_LEVEL:-INFO}"

  # first positional argument is the level of this message
  THIS_LOG_LEVEL="${1:?"Missing LEVEL (DEBUG|INFO|WARNING|ERROR)"}"
  shift

  # check arguments
  if (( USE_STREAM )); then
    if (($# != 0)); then
      echo "Stream mode does not accept a message via arguments" >&2
      exit 1
    fi
  else
    if (($# == 0)); then
      echo "No message provided" >&2
      exit 1
    fi
  fi

  # validate that the requested minimum level is known
  if [[ -z "${LOG_LEVELS["$LOG_LEVEL"]+_}" ]]; then
    echo "Invalid log level: $LOG_LEVEL" >&2
    exit 1
  fi

  # validate that this message's level is known
  if [[ -z "${LOG_LEVELS["$THIS_LOG_LEVEL"]+_}" ]]; then
    echo "Invalid log level: $THIS_LOG_LEVEL" >&2
    exit 1
  fi

  # skip logging if this message is below the threshold
  if (( LOG_LEVELS["$THIS_LOG_LEVEL"] < LOG_LEVELS["$LOG_LEVEL"] )); then
    if (( USE_STREAM )); then
      cat >/dev/null
    fi
    exit 0
  fi

  # avoid timestamp in journal logs
  STDOUT="$(stat -Lc '%d:%i' "/proc/self/fd/1" 2> /dev/null)"
  STDERR="$(stat -Lc '%d:%i' "/proc/self/fd/2" 2> /dev/null)"

  if (( USE_STREAM )); then
    while IFS= read -r LINE; do
      write_message '%s' "$LINE"
    done
  else
    write_message "$@"
  fi
}

function write_message {

  local PRINT_TIMESTAMP
  local TIMESTAMP
  local RESULT

  if [[ -n ${JOURNAL_STREAM:-} && ("$STDOUT" == "$JOURNAL_STREAM" || "$STDERR" == "$JOURNAL_STREAM") ]]; then
    PRINT_TIMESTAMP=0
  else
    PRINT_TIMESTAMP=1
  fi

  TIMESTAMP="$(date -u '+%Y-%m-%dT%H:%M:%S.%3NZ')"

  # send WARNING or ERROR to stderr, others to stdout
  if [[ "$THIS_LOG_LEVEL" == 'WARNING' || "$THIS_LOG_LEVEL" == 'ERROR' ]]; then
    RESULT="$(format_message "$@")"
    printf '%s\n' "$RESULT" >&2
  else
    RESULT="$(format_message "$@")"
    printf '%s\n' "$RESULT"
  fi

  # optionally append the same message to a log file
  if [[ -n "${LOG_FILE:-}" ]]; then
    PRINT_TIMESTAMP=1
    RESULT="$(format_message "$@")"
    printf '%s\n' "$RESULT" >> "$LOG_FILE"
  fi
}

function format_message {

  local FORMAT

  printf '[%s] ' "$THIS_LOG_LEVEL"

  if (( PRINT_TIMESTAMP )); then
    printf '[%s] ' "$TIMESTAMP"
  fi

  for TAG in "${CONTEXT_ARR[@]}"; do
    printf '[%s] ' "$TAG"
  done

  FORMAT="$1"
  shift

  # shellcheck disable=SC2059
  printf "$FORMAT" "$@"
}

function print_usage {
  cat <<EOF
Usage: ${0##*/} [OPTIONS]... <FORMAT> [ARGS]...

-l, --log-level LEVEL         Log level (DEBUG, INFO, WARNING, ERROR; default: INFO)
-f, --log-file FILE           Path to log file (default: no file output)
-m, --marker NAME=VALUE       Add a context tag (e.g. -m name=DefaultLogger)
-s, --stream                  Read lines from stdin and log each line at LEVEL
-h, --help                    Show this help text and exit
EOF
}

set -euo pipefail
main "$@"
exit 0
