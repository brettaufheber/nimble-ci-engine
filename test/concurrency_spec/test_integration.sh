#!/usr/bin/env bash

function test_spec {

  export TEST_DIR="$1"
  export TEST_NAME="$(basename "$TEST_DIR")"

  setup_signal_handling
  set_env_defaults
  create_temp_dir
  create_cgroup_nodes

  for CI_CONFIG_FILE in "$TEST_DIR"/*.yaml; do
    [[ -f "$CI_CONFIG_FILE" ]] || continue
    (
      TEMP_DIR="$TEMP_DIR/$TEST_NAME"

      mkdir -p "$TEMP_DIR"

      export TEST_RESOURCES_DIR="$TEMP_DIR/test/$(basename "$CI_CONFIG_FILE" '.yaml')"
      export STATE_FILE="$TEST_RESOURCES_DIR/state.json"
      STATE_LOCK_FILE="$TEST_RESOURCES_DIR/state.json.lock"
      LOG_DIR="$TEST_RESOURCES_DIR/logs"
      DEFAULT_WORKSPACES_PARENT_DIR="$TEST_RESOURCES_DIR/workspaces"
      KEEP_PREVIOUS_EXECUTIONS="false"
      export SCHEMA_BASE_URI

      log INFO 'Process CI configuration: %s' "$CI_CONFIG_FILE"

      attach_engine
      load_ci_config
      process_directives
      validate_ci_config
      validate_state

      # make the CI configuration available to the pipeline
      echo "$CI_CONFIG" > "$TEST_RESOURCES_DIR/ci.yaml"

      # run pipelines
      orchestrate_pipelines

      show_log_files "$LOG_DIR"
      check_all_pipelines_succeeded

      log INFO 'Finished processing of CI configuration: %s' "$CI_CONFIG_FILE"
    )
  done

  # cleanup routines
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

function check_all_pipelines_succeeded {

  local ISSUES

  ISSUES="$(
    jqw -nc \
      --argfile 'state' "$STATE_FILE" \
      'include "lib/state_validation"; state_issues_pipeline_status($state; . == "success")'
  )"

  if [[ "$ISSUES" != "[]" ]]; then
    log ERROR 'Some pipelines did not execute successfully — issues:\n%s' "$ISSUES"
    return 1
  fi
}
