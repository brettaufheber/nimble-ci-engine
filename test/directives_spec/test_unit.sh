#!/usr/bin/env bash

function test_setup {

  mkdir -p "$TEST_RESOURCES_DIR/settings" "$TEST_RESOURCES_DIR/alpha"

  echo -n '{"global_feature":"on"}' > "$TEST_RESOURCES_DIR/features.json"
  echo -n '["docker","lxd",2001]' > "$TEST_RESOURCES_DIR/groups.json"
  echo -n '{"api_key":"alpha-API-KEY","other":123}' > "$TEST_RESOURCES_DIR/pipeline_alpha.json"
  echo -n 's3cr3t-global' > "$TEST_RESOURCES_DIR/global_secret.txt"
  echo -n 'alpha-token-abc' > "$TEST_RESOURCES_DIR/pipeline_alpha_token.txt"
  echo -n 'beta-token-xyz' > "$TEST_RESOURCES_DIR/pipeline_beta_token.txt"
  echo -n 'true' > "$TEST_RESOURCES_DIR/true.txt"
  echo -n 'settings-main' > "$TEST_RESOURCES_DIR/settings/main.txt"
  echo -n '{"mode":"fast","params":{"threads":2}}' > "$TEST_RESOURCES_DIR/alpha/job_init.json"
  echo -n '{"tests":["unit","integration"]}' > "$TEST_RESOURCES_DIR/alpha/testcases.json"
}

function test_spec {

  export TEST_DIR="$1"
  export TEST_NAME="$(basename "$TEST_DIR")"

  set_env_defaults
  create_temp_dir

  # make these variables available in the ci.yaml file
  export TEST_RESOURCES_DIR="$TEMP_DIR/$TEST_NAME"

  CI_CONFIG_FILE="$TEST_DIR/ci.yaml"  # this variable is required by the CI engine
  CI_RESULT_FILE="$TEST_DIR/result.json"

  test_setup

  load_ci_config
  process_directives
  validate_ci_config

  EXPECTED_JSON="$(jqw '.' "$CI_RESULT_FILE")"
  ACTUAL_JSON="$(jqw '.' <<< "$CI_CONFIG")"

  if [[ "$ACTUAL_JSON" != "$EXPECTED_JSON" ]]; then
    echo "$EXPECTED_JSON" > "$TEST_RESOURCES_DIR/expected.json"
    echo "$ACTUAL_JSON" > "$TEST_RESOURCES_DIR/actual.json"
    log ERROR 'Mismatch: CI_CONFIG differs from %s' "$CI_RESULT_FILE"
    diff -u "$TEST_RESOURCES_DIR/expected.json" "$TEST_RESOURCES_DIR/actual.json" || true
    return 1
  fi

  log INFO 'Success: The generated CI configuration matches the expectation %s' "$CI_RESULT_FILE"

  teardown
}
