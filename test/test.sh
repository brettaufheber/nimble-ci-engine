#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025 Eric Löffler <eric.loeffler@opalia.systems>
# SPDX-License-Identifier: GPL-3.0-or-later

function main {

  SCRIPT_FILE="$(readlink -f "$0")"
  SELF_DIR="$(dirname "$SCRIPT_FILE")"

  case ":$PATH:" in
    *":$SELF_DIR/../lib:"*) ;;
    *) export PATH="$SELF_DIR/../lib:$PATH" ;;
  esac

  setup_std_stream_logging

  if [[ $# -eq 0 ]]; then
    "$SCRIPT_FILE" all
  else

    local CMD

    CMD="$1"
    shift

    case "$CMD" in
      all)
        if [[ $# -eq 0 ]]; then
          "$SCRIPT_FILE" all unit
          "$SCRIPT_FILE" all integration
        elif [[ $# -eq 1 ]]; then
          "$SCRIPT_FILE" all "$1" "$SELF_DIR/../ci_run.sh"
        elif [[ $# -eq 2 ]]; then

          local TEST_TYPE
          local SCRIPT_UNDER_TEST_FILE

          TEST_TYPE="$1"
          SCRIPT_UNDER_TEST_FILE="$2"

          case "$TEST_TYPE" in
            unit)
              run_all_tests "$SCRIPT_UNDER_TEST_FILE" "$TEST_TYPE"
              ;;
            integration)
              # kein globaler Root-Check mehr – wird pro Test entschieden
              run_all_tests "$SCRIPT_UNDER_TEST_FILE" "$TEST_TYPE"
              ;;
            *)
              log ERROR 'Unknown test type: %s' "$TEST_TYPE"
              return 1
              ;;
          esac
        else
          log ERROR 'Unexpected number of arguments'
          return 1
        fi
        ;;
      single)
        run_single_test "$@"
        ;;
      *)
        log ERROR 'Invalid command: %s' "$CMD"
        return 1
        ;;
    esac
  fi
}

function run_single_test {

  local SCRIPT_UNDER_TEST_FILE
  local TEST_SCRIPT_FILE
  local TEST_DIR

  SCRIPT_UNDER_TEST_FILE="${1:?Missing SCRIPT_UNDER_TEST_FILE}"
  TEST_SCRIPT_FILE="${2:?Missing TEST_SCRIPT_FILE}"
  TEST_DIR="${3:?Missing TEST_DIR}"

  if [[ $# -gt 3 ]]; then
    log ERROR 'Unexpected number of arguments'
    return 1
  fi

  if [[ ! -f "$SCRIPT_UNDER_TEST_FILE" || ! -x "$SCRIPT_UNDER_TEST_FILE" ]]; then
     log ERROR 'No executable script under test found: %s' "$SCRIPT_UNDER_TEST_FILE"
    return 1
  fi

  if [[ ! -d "$TEST_DIR" ]]; then
     log ERROR 'Missing test directory: %s' "$TEST_DIR"
    return 1
  fi

  if [[ ! -f "$TEST_SCRIPT_FILE" || ! -x "$TEST_SCRIPT_FILE" ]]; then
     log ERROR 'No executable test script found: %s' "$TEST_SCRIPT_FILE"
    return 1
  fi

  (
    # load code under test (fresh for each test)
    # shellcheck disable=SC1090
    source "$SCRIPT_UNDER_TEST_FILE"

    # load assert definitions
    # shellcheck disable=SC1090,SC1091
    source "$SELF_DIR/asserts.sh"

    # load test definitions
    # shellcheck disable=SC1090,SC1091
    source "$TEST_SCRIPT_FILE"

    # execute the test
    test_spec "$TEST_DIR"
  )
}

function run_all_tests {

  local SCRIPT_FILE_UNDER_TEST
  local TEST_SCRIPT_FILE
  local TEST_DIR
  local TEST_TYPE
  local TOTAL
  local PASSED
  local FAILED
  local SKIPPED
  local FOUND_ANY

  SCRIPT_FILE_UNDER_TEST="$1"
  TEST_TYPE="$2"
  TOTAL=0
  PASSED=0
  FAILED=0
  SKIPPED=0
  FOUND_ANY=0

  while IFS= read -r -d '' TEST_DIR; do
    TEST_SCRIPT_FILE="$TEST_DIR/test_$TEST_TYPE.sh"
    if [[ -f "$TEST_SCRIPT_FILE" ]]; then
      FOUND_ANY=1
      run_test "$SCRIPT_FILE_UNDER_TEST" "$TEST_SCRIPT_FILE" "$TEST_DIR" "$TEST_TYPE"
    fi
  done < <(find "$SELF_DIR" -mindepth 1 -maxdepth 1 -type d -print0 || true)

  if [[ $FOUND_ANY -eq 0 ]]; then
     log WARNING 'No tests found in directory %s' "$SELF_DIR"
  fi

  log INFO 'Summary: TOTAL=%d, OK=%d, FAIL=%d, SKIP=%d' "${TOTAL}" "${PASSED}" "${FAILED}" "${SKIPPED}"
  return $(( FAILED > 0 ? 1 : 0 ))
}

function run_test {

  local SCRIPT_FILE_UNDER_TEST
  local TEST_SCRIPT_FILE
  local TEST_DIR
  local TEST_TYPE
  local TEST_NAME
  local TEST_RC
  local NEEDS_ROOT

  SCRIPT_FILE_UNDER_TEST="$1"
  TEST_SCRIPT_FILE="$2"
  TEST_DIR="$3"
  TEST_TYPE="$4"
  TEST_NAME="$(basename "$TEST_DIR")"
  TEST_RC=0
  NEEDS_ROOT=0

  if [[ "$TEST_TYPE" == "integration" && -f "$TEST_DIR/.root_required" ]]; then
    NEEDS_ROOT=1
  fi

  log -m 'state=STARTED' INFO 'Test %s %s' "$TEST_TYPE" "$TEST_NAME"
  ((++TOTAL))

  if [[ "$NEEDS_ROOT" -eq 1 && "$EUID" -ne 0 ]]; then
    log -m 'state=SKIPPED' WARNING 'Test %s %s requires root (.root_required); skipping' "$TEST_TYPE" "$TEST_NAME"
    ((++SKIPPED))
    return 0
  fi

  "$SCRIPT_FILE" single "$SCRIPT_FILE_UNDER_TEST" "$TEST_SCRIPT_FILE" "$TEST_DIR" || TEST_RC=$?

  if [[ "$TEST_RC" -eq 0 ]]; then
    log -m 'state=PASSED' INFO 'Test %s %s' "$TEST_TYPE" "$TEST_NAME"
    ((++PASSED))
  else
    log -m 'state=FAILED' WARNING 'Test %s %s (exit_code=%d)' "$TEST_TYPE" "$TEST_NAME" "$TEST_RC"
    ((++FAILED))
  fi
}

function setup_std_stream_logging {

  [[ ${LOG_STREAM_ACTIVE:-0} -eq 1 ]] && return
  LOG_STREAM_ACTIVE=1

  exec {ORIG_OUT}>&1 {ORIG_ERR}>&2
  export ORIG_OUT ORIG_ERR LOG_STREAM_ACTIVE=1

  exec 1> >(stdbuf -oL log --stream INFO || true)
  exec 2> >(stdbuf -oL log --stream WARNING || true)
}

set -euo pipefail
main "$@"
exit 0
