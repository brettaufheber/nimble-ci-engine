#!/usr/bin/env bash

function it {

  log INFO '• It %s' "$1"
}

function assert_equals {

  local EXPECTED
  local ACTUAL
  local MESSAGE

  EXPECTED="$1"
  ACTUAL="$2"
  MESSAGE="${3:-'values should be equal'}"

  if [[ "$EXPECTED" == "$ACTUAL" ]]; then
    log INFO '  ✔ Success: %s' "$MESSAGE"
  else
    log WARNING '  ✘ Failure: %s\n    Expected: %s\n    Actual: %s' "$MESSAGE" "$EXPECTED" "$ACTUAL"
    TEST_PARTS_FAILED="$((TEST_PARTS_FAILED+1))"
  fi
}

function assert_not_equals {

  local EXPECTED
  local ACTUAL
  local MESSAGE

  EXPECTED="$1"
  ACTUAL="$2"
  MESSAGE="${3:-'values should not be equal'}"

  if [[ "$EXPECTED" != "$ACTUAL" ]]; then
    log INFO '  ✔ Success: %s' "$MESSAGE"
  else
    log WARNING '  ✘ Failure: %s\n    Expected: %s\n    Actual: %s' "$MESSAGE" "$EXPECTED" "$ACTUAL"
    TEST_PARTS_FAILED="$((TEST_PARTS_FAILED+1))"
  fi
}

function assert_json_eq {

  local EXPECTED
  local ACTUAL
  local MESSAGE

  EXPECTED="$1"
  ACTUAL="$2"
  MESSAGE="${3:-'JSON should be equal'}"

  EXPECTED="$(jqw -c '.' <<< "$EXPECTED")"
  ACTUAL="$(jqw -c '.' <<< "$ACTUAL")"

  assert_equals "$EXPECTED" "$ACTUAL" "$MESSAGE"
}

function assert_exists {

  local PATH_NAME
  local MESSAGE

  PATH_NAME="$1"
  MESSAGE="${2:-'path should exist'}"

  if [[ -e "$PATH_NAME" ]]; then
    log INFO '  ✔ Success: %s' "$MESSAGE"
  else
    log WARNING '  ✘ Failure: %s\n    File: %s' "$MESSAGE" "$PATH_NAME"
    TEST_PARTS_FAILED="$((TEST_PARTS_FAILED+1))"
  fi
}

function assert_not_exists {

  local PATH_NAME
  local MESSAGE

  PATH_NAME="$1"
  MESSAGE="${2:-'path should not exist'}"

  if [[ ! -e "$PATH_NAME" ]]; then
    log INFO '  ✔ Success: %s' "$MESSAGE"
  else
    log WARNING '  ✘ Failure: %s\n    File: %s' "$MESSAGE" "$PATH_NAME"
    TEST_PARTS_FAILED="$((TEST_PARTS_FAILED+1))"
  fi
}

function assert_file_equals {

  local PATH_NAME
  local EXPECTED
  local ACTUAL
  local MESSAGE

  PATH_NAME="$1"
  EXPECTED="$2"
  MESSAGE="${3:-'files should be equal'}"

  if [[ ! -f "$PATH_NAME" ]]; then
    log WARNING '  ✘ Failure: missing file %s' "$PATH_NAME"
    TEST_PARTS_FAILED="$((TEST_PARTS_FAILED+1))"
    return
  fi

  ACTUAL="$(cat "$PATH_NAME")"

  assert_equals "$EXPECTED" "$ACTUAL" "$MESSAGE"
}

function assert_file_contains {

  local PATH_NAME
  local EXPECTED_ENTRY
  local MESSAGE

  PATH_NAME="$1"
  EXPECTED_ENTRY="$2"
  MESSAGE="${3:-'file should contain expected entry'}"

  if [[ ! -f "$PATH_NAME" ]]; then
    log WARNING '  ✘ Failure: missing file %s' "$PATH_NAME"
    TEST_PARTS_FAILED="$((TEST_PARTS_FAILED+1))"
    return
  fi

  if grep -qw "$EXPECTED_ENTRY" "$PATH_NAME"; then
    log INFO '  ✔ Success: %s' "$MESSAGE"
  else
    log WARNING '  ✘ Failure: %s\n    File: %s\n    Expected: %s' \
      "$MESSAGE" "$PATH_NAME" "$EXPECTED_ENTRY"
    TEST_PARTS_FAILED="$((TEST_PARTS_FAILED+1))"
  fi
}

function expect_exit_code {

  local EXPECTED_RC
  local MESSAGE

  EXPECTED_RC="$1"

  if [[ "$2" == "--" ]]; then
    MESSAGE="should get expected exit code $EXPECTED_RC"
    shift 2
  elif [[ "$3" == "--" ]]; then
    MESSAGE="$2"
    shift 3
  fi

  ACTUAL_RC=0

  set +e
  ( set -euo pipefail; "$@" )
  ACTUAL_RC=$?
  set -e

  if [[ "$ACTUAL_RC" -eq "$EXPECTED_RC" ]]; then
    log INFO '  ✔ Success: %s' "$MESSAGE"
  else
    log WARNING '  ✘ Failure: %s\n    Expected: %s\n    Actual: %s\n    Command: %s' \
      "$MESSAGE" "$EXPECTED_RC" "$ACTUAL_RC" "$*"
    TEST_PARTS_FAILED="$((TEST_PARTS_FAILED+1))"
  fi
}
