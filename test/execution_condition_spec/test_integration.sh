#!/usr/bin/env bash

function test_spec {

  export TEST_DIR="$1"
  export TEST_NAME="$(basename "$TEST_DIR")"

  setup_signal_handling
  set_env_defaults
  create_temp_dir
  create_cgroup_nodes
  setup_test_git_repo

  for TEST_SUB_DIR in "$TEST_DIR"/*; do
    CI_CONFIG_FILE="$TEST_SUB_DIR/ci.yaml"
    [[ -f "$CI_CONFIG_FILE" ]] || continue
    (
      TEMP_DIR="$TEMP_DIR/$TEST_NAME"

      mkdir -p "$TEMP_DIR"

      export TEST_RESOURCES_DIR="$TEMP_DIR/test/$(basename "$TEST_SUB_DIR")"
      export STATE_FILE="$TEST_RESOURCES_DIR/state.json"
      STATE_LOCK_FILE="$TEST_RESOURCES_DIR/state.json.lock"
      LOG_DIR="$TEST_RESOURCES_DIR/logs"
      DEFAULT_WORKSPACES_PARENT_DIR="$TEST_RESOURCES_DIR/workspaces"
      KEEP_PREVIOUS_EXECUTIONS="false"

      log INFO 'Process CI configuration: %s' "$CI_CONFIG_FILE"

      attach_engine
      load_ci_config
      process_directives
      validate_ci_config
      validate_state

      # run pipelines
      orchestrate_pipelines

      show_log_files "$LOG_DIR"
      check_all_pipeline_state "$TEST_SUB_DIR/expect.json"

      log INFO 'Finished processing of CI configuration: %s' "$CI_CONFIG_FILE"
    )
  done

  # cleanup routines
  teardown
}

function setup_test_git_repo {

  local TEST_REPO_DIR="$TEMP_DIR/git-local-test.git"
  export TEST_REPO_URI="file://$TEST_REPO_DIR"
  local TEST_REPO_WORK_DIR="$TEMP_DIR/git-local-test"

  git init --bare --initial-branch=main "$TEST_REPO_DIR"
  git init --initial-branch=main "$TEST_REPO_WORK_DIR"

  git -C "$TEST_REPO_WORK_DIR" config user.email "test@example.local"
  git -C "$TEST_REPO_WORK_DIR" config user.name  "Test User"

  echo "= local test repository" > "$TEST_REPO_WORK_DIR/README.adoc"
  git -C "$TEST_REPO_WORK_DIR" add "README.adoc"
  git -C "$TEST_REPO_WORK_DIR" commit -m "Initial commit"

  git -C "$TEST_REPO_WORK_DIR" remote add origin "$TEST_REPO_URI"
  git -C "$TEST_REPO_WORK_DIR" push --set-upstream origin main
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
