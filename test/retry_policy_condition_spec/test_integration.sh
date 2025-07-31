#!/usr/bin/env bash

function test_spec {

  export TEST_DIR="$1"
  export TEST_NAME="$(basename "$TEST_DIR")"

  setup_signal_handling
  set_env_defaults
  create_temp_dir
  create_cgroup_nodes

  TEST_RESOURCES_DIR="$TEMP_DIR/data/$TEST_NAME"

  mkdir -p "$TEST_RESOURCES_DIR"

  CI_CONFIG_FILE="$TEST_DIR/ci.yaml"
  STATE_FILE="$TEST_RESOURCES_DIR/state.json"
  STATE_LOCK_FILE="$TEST_RESOURCES_DIR/state.json.lock"
  LOG_DIR="$TEST_RESOURCES_DIR/logs"
  DEFAULT_WORKSPACES_PARENT_DIR="$TEST_RESOURCES_DIR/workspaces"
  KEEP_PREVIOUS_EXECUTIONS="false"

  (
    log INFO 'Process CI configuration: %s' "$CI_CONFIG_FILE"

    attach_engine
    load_ci_config
    process_directives
    validate_ci_config
    validate_state

    # run pipelines
    orchestrate_pipelines

    show_log_files "$LOG_DIR"
    check_all_pipeline_state "$TEST_DIR/expect.json"

    log INFO 'Finished processing of CI configuration: %s' "$CI_CONFIG_FILE"
  )

  teardown
}

function show_log_files {

  local LOG_DIR
  local CONTENT

  LOG_DIR="$1"

  while IFS= read -r -d '' LOG_FILE; do
    [[ -f "$LOG_FILE" ]] || continue
    CONTENT="$(cat -- "$LOG_FILE" || true)"
    printf '===== BEGIN LOG %s =====\n%s\n===== END LOG %s =====\n' "$LOG_FILE" "$CONTENT" "$LOG_FILE"
  done < <(find "$LOG_DIR" -type f -name '*.log' -print0)
}

function check_all_pipeline_state {

  local EXPECTATION_FILE
  local ISSUES

  EXPECTATION_FILE="$1"

  ISSUES="$(
    jqw -nc \
      --argfile 'expectations' "$EXPECTATION_FILE" \
      --argfile 'state' "$STATE_FILE" \
      'include "lib/state_validation"; state_issues_expectations($state; $expectations)'
  )"

  if [[ "$ISSUES" != "[]" ]]; then
    log ERROR 'Some pipelines did not run as expected — issues:\n%s' "$ISSUES"
    return 1
  fi
}
