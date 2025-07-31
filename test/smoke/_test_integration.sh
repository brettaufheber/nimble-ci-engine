#!/usr/bin/env bash

function test_spec {

  export TEST_DIR="$1"
  export TEST_NAME="$(basename "$TEST_DIR")"

  setup_signal_handling
  create_temp_dir

  export TEST_RESOURCES_DIR="$TEMP_DIR/$TEST_NAME"
  export CI_CONFIG_FILE="$TEST_DIR/ci.yaml"
  export STATE_FILE="$TEST_RESOURCES_DIR/state.json"
  export STATE_LOCK_FILE="$TEST_RESOURCES_DIR/state.json.lock"
  export ENGINE_LOCK_FILE="$TEST_RESOURCES_DIR/ci-engine.lock"
  export LOG_DIR="$TEST_RESOURCES_DIR/logs"
  export DEFAULT_WORKSPACES_PARENT_DIR="$TEST_RESOURCES_DIR/workspaces"
  KEEP_PREVIOUS_EXECUTIONS="false"

  main

  log INFO 'Success: Smoke test executed'
}
