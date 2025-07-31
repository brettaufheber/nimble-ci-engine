#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025 Eric Löffler <eric.loeffler@opalia.systems>
# SPDX-License-Identifier: GPL-3.0-or-later

function main {

  ## external variables
  # CI_CONFIG_FILE
  # STATE_FILE
  # STATE_LOCK_FILE
  # ENGINE_LOCK_FILE
  # LOG_DIR
  # DEFAULT_WORKSPACES_PARENT_DIR
  # $KEEP_PREVIOUS_EXECUTIONS
  # ONLY_PIPELINE (optional)

  ## global variables
  # SCRIPT_FILE
  # INSTALL_DIR (exported)
  # SCHEMA_BASE_URI
  # CI_CONFIG_SCHEMA_VERSION
  # JQ_MODULE_PATH (exported)
  # TEMP_DIR
  # CG_ENGINE_ROOT_DIR
  # CG_ENGINE_DIR
  # CG_JOBS_DIR
  # CI_CONFIG

  set_env_defaults
  setup_std_stream_logging

  if [[ "$EUID" -ne 0 ]]; then
    log ERROR 'Require root privileges'
    return 2
  fi

  if [[ -z "${CI_CONFIG_FILE:-}" ]]; then
    log ERROR 'Required environment variable CI_CONFIG_FILE is not defined'
    return 3
  fi

  if [[ -z "${STATE_FILE:-}" ]]; then
    log ERROR 'Required environment variable STATE_FILE is not defined'
    return 3
  fi

  if [[ -z "${STATE_LOCK_FILE:-}" ]]; then
    log ERROR 'Required environment variable STATE_LOCK_FILE is not defined'
    return 3
  fi

  if [[ -z "${ENGINE_LOCK_FILE:-}" ]]; then
    log ERROR 'Required environment variable ENGINE_LOCK_FILE is not defined'
    return 3
  fi

  if [[ -z "${LOG_DIR:-}" ]]; then
    log ERROR 'Required environment variable LOG_DIR is not defined'
    return 3
  fi

  if [[ -z "${DEFAULT_WORKSPACES_PARENT_DIR:-}" ]]; then
    log ERROR 'Required environment variable DEFAULT_WORKSPACES_PARENT_DIR is not defined'
    return 3
  fi

  if [[ -z "${KEEP_PREVIOUS_EXECUTIONS:-}" ]]; then
    log ERROR 'Required environment variable $KEEP_PREVIOUS_EXECUTIONS is not defined'
    return 3
  fi

  mkdir -p "$(dirname "$STATE_LOCK_FILE")"
  mkdir -p "$(dirname "$ENGINE_LOCK_FILE")"

  # Acquire global engine lock
  exec 200> "$ENGINE_LOCK_FILE"
  flock -xn 200 || {
    log WARNING 'Another CI engine run is active. Exiting.'
    return
  }

  create_temp_dir
  create_cgroup_nodes

  (
    # prepare pipeline orchestration
    attach_engine
    load_ci_config
    process_directives
    validate_ci_config
    validate_state

    # run pipelines
    orchestrate_pipelines
  )

  # cleanup routines
  teardown
}

function set_env_defaults {

  SCRIPT_FILE="$(readlink -f "${BASH_SOURCE[0]}")"
  INSTALL_DIR="$(dirname "$SCRIPT_FILE")"
  SCHEMA_BASE_URI="$(trurl --set "scheme=file" --set "path=$INSTALL_DIR/schema/" )"
  CI_CONFIG_SCHEMA_VERSION="1"  # default value
  JQ_MODULE_PATH="$INSTALL_DIR/scripts"

  export INSTALL_DIR
  export JQ_MODULE_PATH

  case ":$PATH:" in
    *":$INSTALL_DIR/lib:"*) ;;
    *) export PATH="$INSTALL_DIR/lib:$PATH" ;;
  esac
}

function create_temp_dir {

  if [[ -z "${TEMP_DIR:-}" ]]; then
    TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ci_engine-XXXXXXXX")"
  fi
}

function create_cgroup_nodes {

  local CG_ROOT_DIR

  CG_ROOT_DIR="$(cgroupctl mount-point)"
  CG_ENGINE_ROOT_DIR="$(cgroupctl create "$CG_ROOT_DIR" 'ci_engine_root')"
  CG_ENGINE_DIR="$(cgroupctl create "$CG_ENGINE_ROOT_DIR" 'engine' 1)"
  CG_JOBS_DIR="$(cgroupctl create "$CG_ENGINE_ROOT_DIR" 'jobs')"
}

function attach_engine {

  cgroupctl attach "$CG_ENGINE_DIR" "$BASHPID"
}

function load_ci_config {

  # load and normalize the CI config file (JSON or YAML) into CI_CONFIG
  CI_CONFIG="$(jqw -c --yaml-optional '.' "$CI_CONFIG_FILE")"

  # update CI configuration version if defined
  CI_CONFIG_SCHEMA_VERSION="$(
    jqw -r \
      --arg 'default_version' "$CI_CONFIG_SCHEMA_VERSION" \
      '.version // $default_version' <<< "$CI_CONFIG"
  )"
}

function validate_ci_config {

  # validate JSON schema for CI file (without directiveObject occurrences)
  jsonschema \
    --base-uri "$SCHEMA_BASE_URI" \
    --instance <(printf '%s' "$CI_CONFIG") \
    "$INSTALL_DIR/schema/ci_config_schema-v$CI_CONFIG_SCHEMA_VERSION.json"

  # validate pipeline and job names, including needs
  jqw -ne \
    --argjson 'config' "$CI_CONFIG" \
    'include "lib/identifier_validation"; fail_on_errors' \
    > /dev/null
}

function validate_state {

  # start with minimal state file
  if [[ ! -f "$STATE_FILE" ]]; then
    mkdir -p "$(dirname "$STATE_FILE")"
    printf '{ "pipelines": [] }' | jqw '.' > "$STATE_FILE"
  fi

  # validate JSON schema for state file
  jsonschema \
    --base-uri "$SCHEMA_BASE_URI" \
    --instance "$STATE_FILE" \
    "$INSTALL_DIR/schema/state_schema.json"
}

function process_directives {

  # create schema file for CI config with directiveObject extension
  jqw -c \
    --arg 'directive_ref' "./directive_object.json#/definitions/directiveObject" \
    --from-file "$INSTALL_DIR/scripts/create_schema_with_directives.jq" \
    "$INSTALL_DIR/schema/ci_config_schema-v$CI_CONFIG_SCHEMA_VERSION.json" \
    > "$TEMP_DIR/ci_config_schema_with_directives.json"

  # validate JSON schema for CI file with directiveObject extension
  jsonschema \
    --base-uri "$SCHEMA_BASE_URI" \
    --instance <(printf '%s' "$CI_CONFIG") \
    "$TEMP_DIR/ci_config_schema_with_directives.json"

  # apply directives
  substitute_all_directives
}

function substitute_all_directives {

  local SCOPE_TREE
  local ALL_VARIABLES
  local REMAINING_DIRECTIVES
  local ENTRY

  SCOPE_TREE="{}"
  ALL_VARIABLES="$(
    jqw -nc \
      --argjson 'config' "$CI_CONFIG" \
      --from-file "$INSTALL_DIR/scripts/list_variables_entries_with_directives.jq"
  )"
  REMAINING_DIRECTIVES="$(
    jqw -nc \
      --argjson 'config' "$CI_CONFIG" \
      --from-file "$INSTALL_DIR/scripts/list_any_entries_with_directives.jq"
  )"

  while IFS= read -r ENTRY; do
    [[ -z "$ENTRY" ]] && continue
    substitute_directive "$ENTRY"
  done <<< "$ALL_VARIABLES"

  while IFS= read -r ENTRY; do
    [[ -z "$ENTRY" ]] && continue
    substitute_directive "$ENTRY"
  done <<< "$REMAINING_DIRECTIVES"
}

function substitute_directive {

  ## output variables
  # SCOPE_TREE

  local ENTRY
  local JSON_PATH
  local SCOPE
  local TPL_ENV_SUBSET
  local TPL_EXPR
  local TPL_FILTER
  local URI
  local RESULT
  local EXTENSION_RESULT
  local ENV_VAR
  local ENV_VARS_STREAM
  local -a ENV_VARS_ARR

  ENTRY="$1"
  JSON_PATH="$(jqw -c '.path' <<< "$ENTRY")"

  if jqw -e 'has("src") or has("tpl")' > /dev/null <<< "$ENTRY"; then

    SCOPE="$(
      jqw -c \
        --argjson 'path' "$JSON_PATH" \
        --from-file "$INSTALL_DIR/scripts/collect_variables_scope.jq" \
        <<< "$SCOPE_TREE"
    )"

    ENV_VARS_ARR=()
    ENV_VARS_STREAM="$(jqw -c 'to_entries[]' <<< "$SCOPE")"
    while IFS= read -r ENV_VAR; do
      [[ -z "$ENV_VAR" ]] && continue
      ENV_VARS_ARR+=("$(jqw -rj '"\(.key)=\(.value)"' <<< "$ENV_VAR")")
    done <<< "$ENV_VARS_STREAM"

    if jqw -e 'has("src")' > /dev/null <<< "$ENTRY"; then

      TPL_ENV_SUBSET="$(jqw -r '.src' <<< "$ENTRY")"
      URI="$(printf '%s' "$TPL_ENV_SUBSET" | env "${ENV_VARS_ARR[@]}" envsubst)"

      apply_extension "$INSTALL_DIR/extensions/uri_resolvers" "resolver" "URI" "$URI" ENV_VARS_ARR true \
        "URI=$URI"

      RESULT="$EXTENSION_RESULT"

    else
      RESULT='null'
    fi

    if jqw -e 'has("tpl")' > /dev/null <<< "$ENTRY"; then

      TPL_EXPR="$(jqw -r '.tpl' <<< "$ENTRY")"

      TPL_FILTER="$(
        printf 'include "lib/common";\n'
        printf '. as $src | (\n'
        printf '\n%s\n' "$TPL_EXPR"
        printf ')\n'
      )"

      RESULT="$(jqw -c --argjson 'vars' "$SCOPE" "$TPL_FILTER" <<< "$RESULT")"
    fi
  else
    RESULT="$(jqw -c '.value' <<< "$ENTRY")"
  fi

  # write to scope tree if the path is referencing to a variable
  if jqw -e 'type == "array" and length >= 2 and .[-2] == "variables"' > /dev/null <<< "$JSON_PATH"; then
    SCOPE_TREE="$(
      jqw -c \
        --argjson 'path' "$JSON_PATH" \
        --argjson 'value' "$RESULT" \
        'setpath($path; $value)' \
        <<< "$SCOPE_TREE"
    )"
  fi

  # write back to CI config
  CI_CONFIG="$(
    jqw -c \
      --argjson 'path' "$JSON_PATH" \
      --argjson 'value' "$RESULT" \
      'setpath($path; $value)' \
      <<< "$CI_CONFIG"
  )"
}

function record_pipeline_state {

  local PIPELINE_NAME
  local STATUS
  local COMMIT_HASH

  PIPELINE_NAME="$1"
  STATUS="$2"
  COMMIT_HASH="${3:-}"

  (
    # acquire exclusive lock on STATE_LOCK_FILE using FD 201
    flock -x 201

    # generate ISO-8601 UTC timestamp
    TIMESTAMP="$(date -u '+%Y-%m-%dT%H:%M:%S.%3NZ')"

    # create a temporary file to hold the updated state
    TEMP_STATE_FILE="$(mktemp "$STATE_FILE-XXXXXXXX")"

    jqw -n \
      --arg 'pipeline_name' "$PIPELINE_NAME" \
      --arg 'status' "$STATUS" \
      --arg 'commit_hash' "$COMMIT_HASH" \
      --arg 'timestamp' "$TIMESTAMP" \
      --arg 'default_ws_dir' "$DEFAULT_WORKSPACES_PARENT_DIR" \
      --arg 'keep_previous_executions' "$KEEP_PREVIOUS_EXECUTIONS" \
      --argjson 'config' "$CI_CONFIG" \
      --argfile 'state' "$STATE_FILE" \
      --from-file "$INSTALL_DIR/scripts/update_pipeline_state.jq" \
      > "$TEMP_STATE_FILE"

    # atomically replace the original state file with the updated temp file
    mv "$TEMP_STATE_FILE" "$STATE_FILE"

  ) 201> "$STATE_LOCK_FILE"
}

function record_job_state {

  local PIPELINE_NAME
  local JOB_NAME
  local STATUS
  local EXIT_CODE

  PIPELINE_NAME="$1"
  JOB_NAME="$2"
  STATUS="$3"
  EXIT_CODE="${4:-}"

  (
    # acquire exclusive lock on STATE_LOCK_FILE using FD 201
    flock -x 201

    # generate ISO-8601 UTC timestamp
    TIMESTAMP="$(date -u '+%Y-%m-%dT%H:%M:%S.%3NZ')"

    # create a temporary file to hold the updated state
    TEMP_STATE_FILE="$(mktemp "$STATE_FILE-XXXXXXXX")"

    jqw -n \
      --arg 'pipeline_name' "$PIPELINE_NAME" \
      --arg 'job_name' "$JOB_NAME" \
      --arg 'status' "$STATUS" \
      --arg 'exit_code' "$EXIT_CODE" \
      --arg 'timestamp' "$TIMESTAMP" \
      --arg 'log_dir' "$LOG_DIR" \
      --argfile 'state' "$STATE_FILE" \
      --from-file "$INSTALL_DIR/scripts/update_job_state.jq" \
      > "$TEMP_STATE_FILE"

    # atomically replace the original state file with the updated temp file
    mv "$TEMP_STATE_FILE" "$STATE_FILE"

  ) 201> "$STATE_LOCK_FILE"
}

function orchestrate_pipelines {

  local MAX_PARALLEL_PIPELINES
  local SELECTED_PIPELINES
  local READY_PIPELINES
  local PIPELINE_NAME_STREAM
  local PIPELINE_NAME
  local PIPELINE_COUNT
  local IS_PIPELINE_DUE
  local BARE_REPO_URI
  local REPO_REF
  local LAST_COMMIT_HASH
  local CURRENT_COMMIT_HASH

  if [[ -n "${ONLY_PIPELINE:-}" ]]; then
    log INFO 'Execute pipeline %s exclusively' "$ONLY_PIPELINE"
    SELECTED_PIPELINES="$(jqw -c --arg 'p' "$ONLY_PIPELINE" '[ .pipelines[] | select(.name == $p) ]' <<< "$CI_CONFIG")"
  else
    SELECTED_PIPELINES="$(jqw -c '.pipelines' <<< "$CI_CONFIG")"
  fi

  if jqw -e 'length == 0' > /dev/null <<< "$SELECTED_PIPELINES"; then
    log WARNING 'No pipelines to execute — Exiting'
    return
  fi

  PIPELINE_NAME_STREAM="$(jqw -r '.[] | .name' <<< "$SELECTED_PIPELINES")"
  MAX_PARALLEL_PIPELINES="$(
    jqw -r \
      --argfile 'schema' "$INSTALL_DIR/schema/ci_config_schema-v$CI_CONFIG_SCHEMA_VERSION.json" \
      '$schema.definitions.concurrency.properties.max_parallel_pipelines.default as $default
       | .concurrency.max_parallel_pipelines // $default
      ' \
      <<< "$CI_CONFIG"
  )"

  while IFS= read -r PIPELINE_NAME; do

    PIPELINE_COUNT="$(jobs -p | wc -l)"
    while (( PIPELINE_COUNT >= MAX_PARALLEL_PIPELINES && MAX_PARALLEL_PIPELINES > 0 )); do
      wait -n
      PIPELINE_COUNT="$(jobs -p | wc -l)"
    done

    mkdir -p "$TEMP_DIR/pipelines/$PIPELINE_NAME/workspace"

    (
      check_is_pipeline_due "$PIPELINE_NAME"  # defines IS_PIPELINE_DUE

      HAS_REPO_ENTRY="$(
        jqw -c \
          --arg 'p' "$PIPELINE_NAME" \
          '.pipelines[] | select(.name == $p) | has("repository")' \
          <<< "$CI_CONFIG"
      )"

      if ! "$IS_PIPELINE_DUE"; then
        log -m "pipeline=$PIPELINE_NAME" \
          INFO 'Schedule gate denied — Ignoring pipeline'
        rm -rf "$TEMP_WORKSPACE_DIR"  # undefined workspace means no execution
      elif ! "$HAS_REPO_ENTRY"; then
        log -m "pipeline=$PIPELINE_NAME" \
          INFO 'No repository configured — Creating empty workspace...'
        record_pipeline_state "$PIPELINE_NAME" 'pending'
      else

        setup_git_repository "$PIPELINE_NAME" "$TEMP_DIR/pipelines/$PIPELINE_NAME/workspace"

        # compare last deployed commit with current commit
        if [[ "$CURRENT_COMMIT_HASH" == "$LAST_COMMIT_HASH" ]]; then
          log -m "pipeline=$PIPELINE_NAME" \
            INFO 'No new commit on %s with ref %s (hash: %s) — Ignoring pipeline' \
            "$BARE_REPO_URI" "$REPO_REF" "$CURRENT_COMMIT_HASH"
          rm -rf "$TEMP_WORKSPACE_DIR"  # undefined workspace means no execution
        else
          log -m "pipeline=$PIPELINE_NAME" \
            INFO 'New commit detected on %s with ref %s (hash: %s) — Creating workspace...' \
            "$BARE_REPO_URI" "$REPO_REF" "$CURRENT_COMMIT_HASH"
          record_pipeline_state "$PIPELINE_NAME" 'pending' "$CURRENT_COMMIT_HASH"
        fi
      fi
    ) &

  done <<< "$PIPELINE_NAME_STREAM"

  wait  # wait for all Git clone actions to be finished

  # ignore all pipelines which do not require execution
  while IFS= read -r PIPELINE_NAME; do
    if [[ ! -d "$TEMP_DIR/pipelines/$PIPELINE_NAME/workspace" ]]; then
      SELECTED_PIPELINES="$(jqw -c --arg 'p' "$PIPELINE_NAME" 'map(select(.name != $p))' <<< "$SELECTED_PIPELINES")"
    fi
  done <<< "$PIPELINE_NAME_STREAM"

  while :; do

    # find pipelines without dependencies or with dependencies all in final state
    READY_PIPELINES="$(
      jqw -c \
        --argfile 'state' "$STATE_FILE" \
        --from-file "$INSTALL_DIR/scripts/filter_ready_pipelines.jq" \
        <<< "$SELECTED_PIPELINES"
    )"

    # start pipelines from READY_PIPELINES, respecting concurrency limit
    while jqw -e 'length > 0' > /dev/null <<< "$READY_PIPELINES"; do

      PIPELINE_COUNT="$(jobs -p | wc -l)"
      if (( MAX_PARALLEL_PIPELINES > 0 && PIPELINE_COUNT >= MAX_PARALLEL_PIPELINES )); then
        break
      fi

      # take the first ready pipeline
      PIPELINE_NAME="$(jqw -r '.[0].name' <<< "$READY_PIPELINES")"

      # remove it from both pending-list and ready-list
      SELECTED_PIPELINES="$(jqw -c --arg 'p' "$PIPELINE_NAME" 'map(select(.name != $p))' <<< "$SELECTED_PIPELINES")"
      READY_PIPELINES="$(jqw -c --arg 'p' "$PIPELINE_NAME" 'map(select(.name != $p))' <<< "$READY_PIPELINES")"

      # launch the pipeline asynchronously
      run_pipeline "$PIPELINE_NAME" "$TEMP_DIR/pipelines/$PIPELINE_NAME/workspace" &

    done

    # if no pipelines left to start, break out
    if jqw -e 'length == 0' > /dev/null <<< "$SELECTED_PIPELINES"; then
      break
    fi

    # wait for the next pipeline to finish before continuing
    PIPELINE_COUNT="$(jobs -p | wc -l)"
    if (( PIPELINE_COUNT > 0 )); then
      wait -n
    fi

  done

  wait  # ensure that all background jobs actually finish
}

function run_pipeline {

  local PIPELINE_NAME
  local TEMP_WORKSPACE_DIR
  local ENV_VARS
  local EXEC_CONDITION_EXPR
  local EXEC_CONDITION_CONTEXT
  local EXEC_CONDITION_FILTER
  local EXECUTION_DECISION
  local MAX_PARALLEL_JOBS_PER_PIPELINE
  local JOB_NAME_STREAM
  local JOB_NAME
  local JOB_COUNT
  local STATUS

  PIPELINE_NAME="$1"
  TEMP_WORKSPACE_DIR="$2"

  JOBS="$(jqw -c --arg 'p' "$PIPELINE_NAME" '.pipelines[] | select(.name == $p) | .jobs' <<< "$CI_CONFIG")"

  if jqw -e 'length == 0' > /dev/null <<< "$JOBS"; then
    log -m "pipeline=$PIPELINE_NAME" WARNING 'No jobs to run — Ignoring pipeline'
    return
  fi

  ENV_VARS="$(
    jqw -nc \
      --arg 'pipeline_name' "$PIPELINE_NAME" \
      --argjson 'config' "$CI_CONFIG" \
      --argfile 'state' "$STATE_FILE" \
      --from-file "$INSTALL_DIR/scripts/collect_variables.jq"
  )"

  EXEC_CONDITION_EXPR="$(
    jqw -r \
      --arg 'p' "$PIPELINE_NAME" \
      --argfile 'schema' "$INSTALL_DIR/schema/ci_config_schema-v$CI_CONFIG_SCHEMA_VERSION.json" \
      '$schema.definitions.pipeline.properties.condition.default as $default
       | .pipelines[] | select(.name == $p) | .condition // $default
      ' \
      <<< "$CI_CONFIG"
  )"

  EXEC_CONDITION_CONTEXT="$(
    jqw -nc \
      --arg 'pipeline_name' "$PIPELINE_NAME" \
      --argjson 'config' "$CI_CONFIG" \
      --argfile 'state' "$STATE_FILE" \
      --from-file "$INSTALL_DIR/scripts/condition_context_pipeline.jq" \
      <<< "$CI_CONFIG"
  )"

  EXEC_CONDITION_FILTER="$(
    printf 'include "lib/common";\n'
    printf '. as $ctx | (\n'
    cat "$INSTALL_DIR/scripts/lib/condition_helpers.jq"
    printf '\n%s\n' "$EXEC_CONDITION_EXPR"
    printf ')\n'
  )"

  EXECUTION_DECISION="$(
    jqw -c \
      --argjson 'vars' "$ENV_VARS" \
      -- "$EXEC_CONDITION_FILTER" \
      <<< "$EXEC_CONDITION_CONTEXT"
  )"

  if [[ "$EXECUTION_DECISION" == "true" ]]; then
    log -m "pipeline=$PIPELINE_NAME" DEBUG 'Starting pipeline — condition met'
  elif [[ "$EXECUTION_DECISION" == "false" ]]; then
    log -m "pipeline=$PIPELINE_NAME" WARNING 'Skipping pipeline — condition not met'
    record_pipeline_state "$PIPELINE_NAME" 'skipped'
    return
  else
    log -m "pipeline=$PIPELINE_NAME" \
      ERROR 'Expect boolean type from pipeline execution condition; Got: %s' "$EXECUTION_DECISION"
    return 1
  fi

  prepare_workspace "$PIPELINE_NAME" "$TEMP_WORKSPACE_DIR"

  log -m "pipeline=$PIPELINE_NAME" INFO 'Starting CI pipeline'
  record_pipeline_state "$PIPELINE_NAME" 'started'

  JOB_NAME_STREAM="$(jqw -r '.[] | .name' <<< "$JOBS")"
  MAX_PARALLEL_JOBS_PER_PIPELINE="$(
    jqw -r \
      --argfile 'schema' "$INSTALL_DIR/schema/ci_config_schema-v$CI_CONFIG_SCHEMA_VERSION.json" \
      '$schema.definitions.concurrency.properties.max_parallel_jobs_per_pipeline.default as $default
       | .concurrency.max_parallel_jobs_per_pipeline // $default
      ' \
      <<< "$CI_CONFIG"
  )"

  while IFS= read -r JOB_NAME; do
    record_job_state "$PIPELINE_NAME" "$JOB_NAME" 'pending'
  done <<< "$JOB_NAME_STREAM"

  while :; do

    # find jobs without dependencies or with dependencies all in final state
    READY_JOBS="$(
      jqw -c \
        --arg 'pipeline_name' "$PIPELINE_NAME" \
        --argfile 'state' "$STATE_FILE" \
        --from-file "$INSTALL_DIR/scripts/filter_ready_jobs.jq" \
        <<< "$JOBS"
    )"

    # start jobs from READY_JOBS, respecting concurrency limit
    while jqw -e 'length > 0' > /dev/null <<< "$READY_JOBS"; do

      JOB_COUNT="$(jobs -p | wc -l)"
      if (( MAX_PARALLEL_JOBS_PER_PIPELINE > 0 && JOB_COUNT >= MAX_PARALLEL_JOBS_PER_PIPELINE )); then
        break
      fi

      # take the first ready job
      JOB_NAME="$(jqw -r '.[0].name' <<< "$READY_JOBS")"

      # remove it from both pending-list and ready-list
      JOBS="$(jqw -c --arg 'j' "$JOB_NAME" 'map(select(.name != $j))' <<< "$JOBS")"
      READY_JOBS="$(jqw -c --arg 'j' "$JOB_NAME" 'map(select(.name != $j))' <<< "$READY_JOBS")"

      # launch the job asynchronously
      run_job "$PIPELINE_NAME" "$JOB_NAME" &

    done

    # break if no more jobs remain to be scheduled
    if jqw -e 'length == 0' > /dev/null <<< "$JOBS"; then
      break
    fi

    # wait for the next job to finish before re-evaluating
    JOB_COUNT="$(jobs -p | wc -l)"
    if (( JOB_COUNT > 0 )); then
      wait -n
    fi

  done

  wait  # ensure that all background jobs actually finish

  # determine the pipeline status based on the job states
  STATUS="$(
    jqw -nr \
      --arg 'pipeline_name' "$PIPELINE_NAME" \
      --argfile 'state' "$STATE_FILE" \
      --from-file "$INSTALL_DIR/scripts/compute_pipeline_status.jq"
  )"

  # record final pipeline state
  record_pipeline_state "$PIPELINE_NAME" "$STATUS"
}

function run_job {

  local PIPELINE_NAME
  local JOB_NAME
  local ENV_VARS
  local EXEC_CONDITION_EXPR
  local EXEC_CONDITION_CONTEXT
  local EXEC_CONDITION_FILTER
  local EXEC_DECISION
  local RETRY_CONDITION_EXPR
  local RETRY_BACKOFF
  local RETRY_CONDITION_CONTEXT
  local RETRY_CONDITION_FILTER
  local RETRY_DECISION
  local ATTEMPT_CONT
  local LOG_FILE
  local WORKSPACE_DIR
  local CURRENT_UID
  local CURRENT_GID
  local PASSWD_LIST
  local GROUP_LIST
  local SETPRIV_ARGS
  local JOB_STEPS

  PIPELINE_NAME="$1"
  JOB_NAME="$2"

  ENV_VARS="$(
    jqw -nc \
      --arg 'pipeline_name' "$PIPELINE_NAME" \
      --arg 'job_name' "$JOB_NAME" \
      --argjson 'config' "$CI_CONFIG" \
      --argfile 'state' "$STATE_FILE" \
      --from-file "$INSTALL_DIR/scripts/collect_variables.jq"
  )"

  EXEC_CONDITION_EXPR="$(
    jqw -r \
      --arg 'p' "$PIPELINE_NAME" \
      --arg 'j' "$JOB_NAME" \
      --argfile 'schema' "$INSTALL_DIR/schema/ci_config_schema-v$CI_CONFIG_SCHEMA_VERSION.json" \
      '$schema.definitions.job.properties.condition.default as $default
       | .pipelines[] | select(.name == $p) | .jobs[] | select(.name == $j) | .condition // $default
      ' \
      <<< "$CI_CONFIG"
  )"

  EXEC_CONDITION_CONTEXT="$(
    jqw -nc \
      --arg 'pipeline_name' "$PIPELINE_NAME" \
      --arg 'job_name' "$JOB_NAME" \
      --argjson 'config' "$CI_CONFIG" \
      --argfile 'state' "$STATE_FILE" \
      --from-file "$INSTALL_DIR/scripts/condition_context_job.jq" \
      <<< "$CI_CONFIG"
  )"

  EXEC_CONDITION_FILTER="$(
    printf 'include "lib/common";\n'
    printf '. as $ctx | (\n'
    cat "$INSTALL_DIR/scripts/lib/condition_helpers.jq"
    printf '\n%s\n' "$EXEC_CONDITION_EXPR"
    printf ')\n'
  )"

  EXEC_DECISION="$(
    jqw -c \
      --argjson 'vars' "$ENV_VARS" \
      -- "$EXEC_CONDITION_FILTER" \
      <<< "$EXEC_CONDITION_CONTEXT"
  )"

  if [[ "$EXEC_DECISION" == "true" ]]; then
    log -m "pipeline=$PIPELINE_NAME" -m "job=$JOB_NAME" DEBUG 'Starting job — condition met'
  elif [[ "$EXEC_DECISION" == "false" ]]; then
    log -m "pipeline=$PIPELINE_NAME" -m "job=$JOB_NAME" WARNING 'Skipping job — condition not met'
    record_job_state "$PIPELINE_NAME" "$JOB_NAME" 'skipped'
    return
  else
    log -m "pipeline=$PIPELINE_NAME" -m "job=$JOB_NAME" \
      ERROR 'Expect boolean type from job execution condition; got: %s' "$EXEC_DECISION"
    return 1
  fi

  LOG_FILE="$(
    jqw -r --arg 'p' "$PIPELINE_NAME" --arg 'j' "$JOB_NAME" \
      '.pipelines[] | select(.name == $p) | .latest_execution.jobs[] | select(.name == $j) | .log_file' \
      "$STATE_FILE"
  )"

  mkdir -p "$(dirname "$LOG_FILE")"
  touch "$LOG_FILE"

  WORKSPACE_DIR="$(
    jqw -r --arg 'p' "$PIPELINE_NAME" \
      '.pipelines[] | select(.name == $p) | .latest_execution.workspace_dir' \
      "$STATE_FILE"
  )"

  CURRENT_UID="$(id -u)"
  CURRENT_GID="$(id -g)"
  PASSWD_LIST="$(getent passwd)"
  GROUP_LIST="$(getent group)"

  SETPRIV_ARGS="$(
    jqw -nc \
      --arg 'pipeline_name' "$PIPELINE_NAME" \
      --arg 'job_name' "$JOB_NAME" \
      --arg 'default_uid' "$CURRENT_UID" \
      --arg 'default_gid' "$CURRENT_GID" \
      --arg 'passwd' "$PASSWD_LIST" \
      --arg 'group' "$GROUP_LIST" \
      --argjson 'config' "$CI_CONFIG" \
      --argfile 'schema' "$INSTALL_DIR/schema/ci_config_schema-v$CI_CONFIG_SCHEMA_VERSION.json" \
      --from-file "$INSTALL_DIR/scripts/build_setpriv_args.jq"
  )"

  JOB_STEPS="$(
    jqw -c --arg 'p' "$PIPELINE_NAME" --arg 'j' "$JOB_NAME" \
      '.pipelines[] | select(.name == $p) | .jobs[] | select(.name == $j) | .steps' \
       <<< "$CI_CONFIG"
  )"

  RETRY_CONDITION_EXPR="$(
    jqw -r \
      --arg 'p' "$PIPELINE_NAME" \
      --arg 'j' "$JOB_NAME" \
      --argfile 'schema' "$INSTALL_DIR/schema/ci_config_schema-v$CI_CONFIG_SCHEMA_VERSION.json" \
      '$schema.definitions.retryPolicy.properties.condition.default as $default
       | .pipelines[] | select(.name == $p) | .jobs[] | select(.name == $j) | .retry_policy.condition // $default
      ' \
      <<< "$CI_CONFIG"
  )"

  RETRY_BACKOFF="$(
    jqw -r \
      --arg 'p' "$PIPELINE_NAME" \
      --arg 'j' "$JOB_NAME" \
      --argfile 'schema' "$INSTALL_DIR/schema/ci_config_schema-v$CI_CONFIG_SCHEMA_VERSION.json" \
      '$schema.definitions.retryPolicy.properties.backoff.default as $default
       | .pipelines[] | select(.name == $p) | .jobs[] | select(.name == $j) | .retry_policy.backoff // $default
      ' \
      <<< "$CI_CONFIG"
  )"

  RETRY_BACKOFF="$(duration2seconds "$RETRY_BACKOFF")"

  mkdir -p "$TEMP_DIR/pipelines/$PIPELINE_NAME/jobs/$JOB_NAME"

  while :; do

    ATTEMPT_CONT="$(
      jqw -r --arg 'p' "$PIPELINE_NAME" --arg 'j' "$JOB_NAME" \
        '.pipelines[] | select(.name == $p)
         | .latest_execution.jobs[]
         | select(.name == $j)
         | (.previous_attempts | length) + 1
        ' "$STATE_FILE"
    )"

    manage_async_job "$PIPELINE_NAME" "$JOB_NAME" "$ATTEMPT_CONT" "$LOG_FILE" \
      "$WORKSPACE_DIR" "$SETPRIV_ARGS" "$ENV_VARS" "$JOB_STEPS"

    RETRY_CONDITION_CONTEXT="$(
      jqw -nc \
        --arg 'pipeline_name' "$PIPELINE_NAME" \
        --arg 'job_name' "$JOB_NAME" \
        --argjson 'config' "$CI_CONFIG" \
        --argfile 'state' "$STATE_FILE" \
        --from-file "$INSTALL_DIR/scripts/retry_policy_context_job.jq" \
        <<< "$CI_CONFIG"
    )"

    RETRY_CONDITION_FILTER="$(
      printf 'include "lib/common";\n'
      printf '. as $ctx | (\n'
      cat "$INSTALL_DIR/scripts/lib/retry_policy_helpers.jq"
      printf '\n%s\n' "$RETRY_CONDITION_EXPR"
      printf ')\n'
    )"

    RETRY_DECISION="$(
      jqw -c \
        --argjson 'vars' "$ENV_VARS" \
        -- "$RETRY_CONDITION_FILTER" \
        <<< "$RETRY_CONDITION_CONTEXT"
    )"

    if [[ "$RETRY_DECISION" == "true" ]]; then
      log -f "$LOG_FILE" -m "pipeline=$PIPELINE_NAME" -m "job=$JOB_NAME" \
        INFO 'Retrying job in %s seconds (attempt %d)' "$RETRY_BACKOFF" "$(( ATTEMPT_CONT + 1 ))"
      sleep "$RETRY_BACKOFF"
    elif [[ "$RETRY_DECISION" == "false" ]]; then
      break
    else
      log -m "pipeline=$PIPELINE_NAME" -m "job=$JOB_NAME" \
        ERROR 'Expected boolean from retry condition; got: %s' "$RETRY_DECISION"
      return 1
    fi

  done
}

function manage_async_job {

  local PIPELINE_NAME
  local JOB_NAME
  local ATTEMPT_CONT
  local LOG_FILE
  local WORKSPACE_DIR
  local SETPRIV_ARGS
  local ENV_VARS
  local JOB_STEPS
  local TIMEOUT_DURATION
  local TIMEOUT_TERMINATION_GRACE_PERIOD
  local MEMORY_LIMIT
  local MEMORY_THROTTLE_MARK
  local CPU_LIMIT
  local CPU_WEIGHT
  local CG_JOB_DIR
  local JOB_PID
  local WATCHER_PID
  local EXIT_CODE
  local STATUS

  PIPELINE_NAME="$1"
  JOB_NAME="$2"
  ATTEMPT_CONT="$3"
  LOG_FILE="$4"
  WORKSPACE_DIR="$5"
  SETPRIV_ARGS="$6"
  ENV_VARS="$7"
  JOB_STEPS="$8"

  TIMEOUT_DURATION="$(
    jqw -r --arg 'p' "$PIPELINE_NAME" --arg 'j' "$JOB_NAME" \
      '.pipelines[] | select(.name == $p) | .jobs[] | select(.name == $j)
       | .restrictions.timeout.duration // empty
      ' \
      <<< "$CI_CONFIG"
  )"

  TIMEOUT_TERMINATION_GRACE_PERIOD="$(
    jqw -r \
      --arg 'p' "$PIPELINE_NAME" \
      --arg 'j' "$JOB_NAME" \
      --argfile 'schema' "$INSTALL_DIR/schema/ci_config_schema-v$CI_CONFIG_SCHEMA_VERSION.json" \
      '$schema.definitions.timeoutRestriction.properties.termination_grace_period.default as $default
       | .pipelines[] | select(.name == $p) | .jobs[] | select(.name == $j)
       | .restrictions.timeout.termination_grace_period // $default
      ' \
      <<< "$CI_CONFIG"
  )"

  MEMORY_LIMIT="$(
    jqw -r --arg 'p' "$PIPELINE_NAME" --arg 'j' "$JOB_NAME" \
      '.pipelines[] | select(.name == $p) | .jobs[] | select(.name == $j)
       | .restrictions.memory.limit // empty
      ' \
      <<< "$CI_CONFIG"
  )"

  MEMORY_THROTTLE_MARK="$(
    jqw -r --arg 'p' "$PIPELINE_NAME" --arg 'j' "$JOB_NAME" \
      '.pipelines[] | select(.name == $p) | .jobs[] | select(.name == $j)
       | .restrictions.memory.throttle_mark // empty
      ' \
      <<< "$CI_CONFIG"
  )"

  CPU_LIMIT="$(
    jqw -r --arg 'p' "$PIPELINE_NAME" --arg 'j' "$JOB_NAME" \
      '.pipelines[] | select(.name == $p) | .jobs[] | select(.name == $j)
       | .restrictions.cpu.limit // empty
      ' \
      <<< "$CI_CONFIG"
  )"

  CPU_WEIGHT="$(
    jqw -r --arg 'p' "$PIPELINE_NAME" --arg 'j' "$JOB_NAME" \
      '.pipelines[] | select(.name == $p) | .jobs[] | select(.name == $j)
       | .restrictions.cpu.weight // empty
      ' \
      <<< "$CI_CONFIG"
  )"

  if [[ -n "$TIMEOUT_DURATION" ]]; then
    TIMEOUT_DURATION="$(duration2seconds "$TIMEOUT_DURATION")"
  fi

  TIMEOUT_TERMINATION_GRACE_PERIOD="$(duration2seconds "$TIMEOUT_TERMINATION_GRACE_PERIOD")"

  log -f "$LOG_FILE" -m "pipeline=$PIPELINE_NAME" -m "job=$JOB_NAME" \
    INFO 'Starting job (attempt %d)' "$ATTEMPT_CONT"
  record_job_state "$PIPELINE_NAME" "$JOB_NAME" 'started'

  # create a unique cgroup directory for this job execution
  CG_JOB_DIR="$(cgroupctl create "$CG_JOBS_DIR" 'job' 1)"

  # launch the actual job inside the newly created cgroup
  (
    # place this subshell (and its children) into the cgroup
    cgroupctl attach "$CG_JOB_DIR" "$BASHPID"

    if [[ -n "$MEMORY_LIMIT" ]]; then
      cgroupctl set-memory-hard-limit "$CG_JOB_DIR" "$MEMORY_LIMIT"
    fi

    if [[ -n "$MEMORY_THROTTLE_MARK" ]]; then
      cgroupctl set-memory-soft-limit "$CG_JOB_DIR" "$MEMORY_THROTTLE_MARK"
    fi

    if [[ -n "$CPU_LIMIT" ]]; then
      cgroupctl set-cpu-limit "$CG_JOB_DIR" "$CPU_LIMIT"
    fi

    if [[ -n "$CPU_WEIGHT" ]]; then
      cgroupctl set-cpu-weight "$CG_JOB_DIR" "$CPU_WEIGHT"
    fi

    # execute the defined job steps with provided context
    run_job_steps "$PIPELINE_NAME" "$JOB_NAME" "$LOG_FILE" "$WORKSPACE_DIR" "$SETPRIV_ARGS" "$ENV_VARS" "$JOB_STEPS"
  ) &
  JOB_PID=$!

  # only install watcher if timeout is configured
  if [[ -n "$TIMEOUT_DURATION" ]]; then
    (
      # wait until the timeout duration elapses (using millisecond precision)
      sleep "$TIMEOUT_DURATION"

      # mark that a timeout occurred
      touch "$TEMP_DIR/pipelines/$PIPELINE_NAME/jobs/$JOB_NAME/.killed"

      # attempt graceful shutdown: send SIGTERM to all processes inside the cgroup
      cgroupctl gracefully-terminate "$CG_JOB_DIR"

      # wait for the configured grace period before forcing termination
      # force kill for any remaining process: send SIGKILL to all processes inside cgroup
      cgroupctl force-terminate "$CG_JOB_DIR" "$TIMEOUT_TERMINATION_GRACE_PERIOD"
    ) &
    WATCHER_PID=$!
  fi

  # wait for the job to finish and capture its exit code
  if wait "$JOB_PID"; then
    EXIT_CODE=0
  else
    EXIT_CODE=$?
  fi

  # cleanup the watcher
  if [[ -n "${WATCHER_PID-}" ]]; then  # is the watcher created?
    kill -STOP "$WATCHER_PID" 2>/dev/null || true  # stop the watcher
    if [[ -f "$TEMP_DIR/pipelines/$PIPELINE_NAME/jobs/$JOB_NAME/.killed" ]]; then  # check for termination mark
      kill -CONT "$WATCHER_PID" 2>/dev/null || true  # continue watcher
      wait "$WATCHER_PID"  # wait and catch any error codes
    else
      kill -KILL "$WATCHER_PID" 2>/dev/null || true  # forced kill
      wait "$WATCHER_PID" || true  # wait and ignore any error codes
    fi
  fi

  # in case no timeout was triggered, it should be ensured that all child processes are terminated
  if [[ ! -f "$TEMP_DIR/pipelines/$PIPELINE_NAME/jobs/$JOB_NAME/.killed" ]]; then
    cgroupctl gracefully-terminate "$CG_JOB_DIR"
    cgroupctl force-terminate "$CG_JOB_DIR" "$TIMEOUT_TERMINATION_GRACE_PERIOD"
  fi

  # tear down the cgroup
  cgroupctl destroy "$CG_JOB_DIR"

  # record final job status
  if [[ -f "$TEMP_DIR/pipelines/$PIPELINE_NAME/jobs/$JOB_NAME/.killed" ]]; then
    STATUS='timeout'
  elif (( EXIT_CODE == 0 )); then
    STATUS='success'
  else
    STATUS='failure'
  fi

  # record final job status
  record_job_state "$PIPELINE_NAME" "$JOB_NAME" "$STATUS" "$EXIT_CODE"

  # remove timeout mark for possible retries
  rm -f "$TEMP_DIR/pipelines/$PIPELINE_NAME/jobs/$JOB_NAME/.killed"

  # log summary about this job execution
  log -f "$LOG_FILE" -m "pipeline=$PIPELINE_NAME" -m "job=$JOB_NAME" \
    INFO 'Finished job (attempt %d) with status=%s and exit_code=%d' "$ATTEMPT_CONT" "$STATUS" "$EXIT_CODE"
}

function run_job_steps {

  local PIPELINE_NAME
  local JOB_NAME
  local LOG_FILE
  local WORKSPACE_DIR
  local SETPRIV_ARG
  local SETPRIV_ARGS
  local SETPRIV_ARGS_STREAM
  local ENV_VAR
  local ENV_VARS
  local ENV_VARS_STREAM
  local JOB_STEP
  local JOB_STEPS
  local JOB_STEPS_STREAM
  local BASH_BIN
  local CI_USER
  local -a SETPRIV_ARGS_ARR
  local -a ENV_VARS_ARR

  PIPELINE_NAME="$1"
  JOB_NAME="$2"
  LOG_FILE="$3"
  WORKSPACE_DIR="$4"
  SETPRIV_ARGS="$5"
  ENV_VARS="$6"
  JOB_STEPS="$7"

  BASH_BIN="$(command -v bash)"

  SETPRIV_ARGS_ARR=()
  SETPRIV_ARGS_STREAM="$(jqw -c '.[]' <<< "$SETPRIV_ARGS")"
  while IFS= read -r SETPRIV_ARG; do
    [[ -z "$SETPRIV_ARG" ]] && continue
    SETPRIV_ARGS_ARR+=("$(jqw -rj '.' <<< "$SETPRIV_ARG")")
  done <<< "$SETPRIV_ARGS_STREAM"

  # get the USER variable
  CI_USER="$(setpriv "${SETPRIV_ARGS_ARR[@]}" -- id -un)"

  ENV_VARS_ARR=(
    "LANG=${LANG:-'C.UTF-8'}"
    "USER=$CI_USER"
    "HOME=$WORKSPACE_DIR"
    "SHELL=$BASH_BIN"
  )

  ENV_VARS_STREAM="$(jqw -c 'to_entries[]' <<< "$ENV_VARS")"
  while IFS= read -r ENV_VAR; do
    [[ -z "$ENV_VAR" ]] && continue
    ENV_VARS_ARR+=("$(jqw -rj '"\(.key)=\(.value)"' <<< "$ENV_VAR")")
  done <<< "$ENV_VARS_STREAM"

  # Execute job steps with strict isolation:
  # - clean environment (env --ignore-environment; whitelist only)
  # - fixed working directory (--chdir="$WORKSPACE_DIR")
  # - HOME confined to workspace (HOME="$WORKSPACE_DIR")
  # - explicit user/group via setpriv (--reuid/--regid)
  # - supplementary groups controlled (--init-groups or --groups <GIDs>)
  # - no privilege escalation when configured (--no-new-privs)
  # - capabilities dropped (--inh-caps=-all, --ambient-caps=-all)
  # - separated stdin (</dev/null); no TTY; stdout+stderr -> log file
  # - fail-fast shell (-euo pipefail)
  # - per-step fresh process (no shared shell state between steps)
  JOB_STEPS_STREAM="$(jqw -c '.[]' <<< "$JOB_STEPS")"
  while IFS= read -r JOB_STEP; do
    [[ -z "$JOB_STEP" ]] && continue
    JOB_STEP="$(jqw -rj '.' <<< "$JOB_STEP")"
    log -f "$LOG_FILE" -m "pipeline=$PIPELINE_NAME" -m "job=$JOB_NAME" DEBUG 'Executing job step:\n%s' "$JOB_STEP"
    setpriv "${SETPRIV_ARGS_ARR[@]}" --inh-caps=-all --ambient-caps=-all -- \
      env --ignore-environment --chdir="$WORKSPACE_DIR" "${ENV_VARS_ARR[@]}" \
        "$BASH_BIN" -euo pipefail -c "$JOB_STEP" < /dev/null &>> "$LOG_FILE"
  done <<< "$JOB_STEPS_STREAM"
}

function check_is_pipeline_due {

  ## output variables
  # IS_PIPELINE_DUE

  local PIPELINE_NAME
  local HAS_SCHEDULE_ENTRY
  local WHEN_EXPRESSION
  local FORMAT
  local TIMEZONE
  local BASE_TIMESTAMP
  local EXTENSION_RESULT
  local RESULT_DIFF
  local -a ENV_VARS_ARR

  PIPELINE_NAME="$1"

  ENV_VARS_ARR=()

  HAS_SCHEDULE_ENTRY="$(
    jqw -c \
      --arg 'p' "$PIPELINE_NAME" \
      '.pipelines[] | select(.name == $p) | has("schedule")' \
      <<< "$CI_CONFIG"
  )"

  if ! "$HAS_SCHEDULE_ENTRY"; then
    IS_PIPELINE_DUE=true
    log -m "pipeline=$PIPELINE_NAME" \
      DEBUG 'No schedule configured — The pipeline is due by default'
    return 0
  fi

  WHEN_EXPRESSION="$(
    jqw -r --arg 'p' "$PIPELINE_NAME" \
      '.pipelines[] | select(.name == $p) | .schedule.when' \
      <<< "$CI_CONFIG"
  )"

  FORMAT="$(
    jqw -r --arg 'p' "$PIPELINE_NAME" \
      '.pipelines[] | select(.name == $p) | .schedule.format' \
      <<< "$CI_CONFIG"
  )"

  TIMEZONE="$(
    jqw -r \
      --arg 'p' "$PIPELINE_NAME" \
      --argfile 'schema' "$INSTALL_DIR/schema/ci_config_schema-v$CI_CONFIG_SCHEMA_VERSION.json" \
      '$schema.definitions.schedule.properties.timezone.default as $default
       | .pipelines[] | select(.name == $p) | .schedule.timezone // $default
      ' \
      <<< "$CI_CONFIG"
  )"

  JITTER="$(
    jqw -r \
      --arg 'p' "$PIPELINE_NAME" \
      --argfile 'schema' "$INSTALL_DIR/schema/ci_config_schema-v$CI_CONFIG_SCHEMA_VERSION.json" \
      '$schema.definitions.schedule.properties.jitter.default as $default
       | .pipelines[] | select(.name == $p) | .schedule.jitter // $default
      ' \
      <<< "$CI_CONFIG"
  )"

  BASE_TIMESTAMP="$(
    jqw -r --arg 'p' "$PIPELINE_NAME" \
      '.pipelines[] | select(.name == $p) | .latest_execution.timestamp' \
      "$STATE_FILE"
  )"

  DURATION_MS="$(
    jqw -r --arg 'p' "$PIPELINE_NAME" \
      '.pipelines[] | select(.name == $p) | .latest_execution.duration_ms' \
      "$STATE_FILE"
  )"

  apply_extension "$INSTALL_DIR/extensions/when_evaluators" "evaluator" "schedule format" "$FORMAT" ENV_VARS_ARR false \
    "EXPRESSION=$WHEN_EXPRESSION" \
    "TIMEZONE=$TIMEZONE" \
    "JITTER=$JITTER" \
    "BASE_TIMESTAMP=$BASE_TIMESTAMP" \
    "DURATION_MS=$DURATION_MS"


  RESULT_DIFF="$(jqw -c 'fromjson | .delta_s' <<< "$EXTENSION_RESULT")"

  if [[ "$RESULT_DIFF" == "null" ]]; then
    log -m "pipeline=$PIPELINE_NAME" DEBUG 'Next occurrence will never be reached — pipeline is not due'
    IS_PIPELINE_DUE=false
  elif (( RESULT_DIFF < 0 )); then
    log -m "pipeline=$PIPELINE_NAME" DEBUG 'Next occurrence is in the future — pipeline is not due'
    IS_PIPELINE_DUE=false
  else
    log -m "pipeline=$PIPELINE_NAME" DEBUG 'Next occurrence reached or passed — pipeline is due'
    IS_PIPELINE_DUE=true
  fi
}

function apply_extension {

  ## output variables
  # EXTENSION_RESULT

  local EXTENSION_DIR
  local EXTENSION_TYPE
  local KEY_NAME
  local KEY
  local USE_REGEX_KEYS
  local MAPPING
  local OUTPUT_FILE
  local ENV_WHITELIST
  local ARG
  local CMD_PART
  local CMD
  local -a CMD_ARR
  local -n _ENV_VARS_ARR

  EXTENSION_DIR="$1"
  EXTENSION_TYPE="$2"
  KEY_NAME="$3"
  KEY="$4"
  _ENV_VARS_ARR="$5"
  USE_REGEX_KEYS="$6"

  shift 6

  MAPPING="$(jqw -c '.' "$EXTENSION_DIR/mapping.json")"

  CMD="$(
    jqw -c \
      --arg 'use_regex_keys' "$USE_REGEX_KEYS" \
      --arg 'key' "$KEY" \
      --from-file "$INSTALL_DIR/scripts/select_tool.jq" \
      <<< "$MAPPING"
  )"

  if [[ "$CMD" == "null" ]]; then
    log ERROR 'No %s found for %s %s' "$EXTENSION_TYPE" "$KEY_NAME" "$KEY"
    return 1
  fi

  CMD="$(jqw -c '.[]' <<< "$CMD")"

  ENV_WHITELIST=''
  for ARG in "$@"; do
    ENV_WHITELIST="$ENV_WHITELIST \$${ARG%%=*}"
  done

  CMD_ARR=()
  while IFS= read -r CMD_PART; do
    [[ -z "$CMD_PART" ]] && continue
    CMD_PART="$(jqw -rj '.' <<< "$CMD_PART")"
    CMD_PART="$(env "$@" envsubst "$ENV_WHITELIST" <<< "$CMD_PART")"
    CMD_ARR+=("$CMD_PART")
  done <<< "$CMD"

  if ((${#CMD_ARR[@]} == 0)); then
    log ERROR 'No command specified for %s with %s %s' "$EXTENSION_TYPE" "$KEY_NAME" "$KEY"
    return 1
  fi

  OUTPUT_FILE="$(mktemp "$TEMP_DIR/$EXTENSION_TYPE-output-XXXXXXXX")"

  env --chdir="$INSTALL_DIR" "${_ENV_VARS_ARR[@]}" "${CMD_ARR[@]}" > "$OUTPUT_FILE" || {
    log ERROR 'The %s %s failed for %s %s' "$EXTENSION_TYPE" "${CMD_ARR[0]}" "$KEY_NAME" "$KEY"
    return 7
  }

  EXTENSION_RESULT="$(
    jqw -Rsc \
      --argfile 'schema' "$INSTALL_DIR/schema/common_patterns.json" \
      --from-file "$INSTALL_DIR/scripts/validate_free_input.jq" \
      "$OUTPUT_FILE"
  )" || {
    log ERROR 'The %s %s produced invalid data for %s %s' "$EXTENSION_TYPE" "${CMD_ARR[0]}" "$KEY_NAME" "$KEY"
    return 8
  }
}

function setup_git_repository {

  ## output variables
  # BARE_REPO_URI
  # REPO_REF
  # LAST_COMMIT_HASH
  # CURRENT_COMMIT_HASH

  local PIPELINE_NAME
  local TEMP_WORKSPACE_DIR
  local -x GIT_TERMINAL_PROMPT  # exported (-x)

  PIPELINE_NAME="$1"
  TEMP_WORKSPACE_DIR="$2"

  GIT_TERMINAL_PROMPT=0

  BARE_REPO_URI="$(
    jqw -r --arg 'p' "$PIPELINE_NAME" \
      '.pipelines[] | select(.name == $p) | .repository.uri' \
      <<< "$CI_CONFIG"
  )"

  REPO_REF="$(
    jqw -r --arg 'p' "$PIPELINE_NAME" \
      '.pipelines[] | select(.name == $p) | .repository.ref' \
      <<< "$CI_CONFIG"
  )"

  LAST_COMMIT_HASH="$(
    jqw -r --arg 'p' "$PIPELINE_NAME" \
      '.pipelines[] | select(.name == $p) | .latest_execution.repository.commit_hash // empty' \
      "$STATE_FILE"
  )"

  if [[ -n "$LAST_COMMIT_HASH" ]]; then

    if ! CURRENT_COMMIT_HASH="$(git ls-remote --heads "$BARE_REPO_URI" "$REPO_REF" | awk '{print $1}')" ||
        [[ -z "$CURRENT_COMMIT_HASH" ]]; then
      if ! CURRENT_COMMIT_HASH="$(git ls-remote --tags "$BARE_REPO_URI" "$REPO_REF" | awk '{print $1}')" ||
          [[ -z "$CURRENT_COMMIT_HASH" ]]; then
        log -m "pipeline=$PIPELINE_NAME" ERROR 'Failed to query ref %s on %s' "$REPO_REF" "$BARE_REPO_URI"
        return 6
      fi
    fi

    # pre-comparison to reduce overhead
    if [[ "$CURRENT_COMMIT_HASH" == "$LAST_COMMIT_HASH" ]]; then
      return
    fi
  fi

  clone_git_repository "$PIPELINE_NAME" "$TEMP_WORKSPACE_DIR" "$BARE_REPO_URI" "$REPO_REF"

  CURRENT_COMMIT_HASH="$(git -C "$TEMP_WORKSPACE_DIR" rev-parse HEAD)"
}

function clone_git_repository {

  local PIPELINE_NAME
  local TEMP_WORKSPACE_DIR
  local BARE_REPO_URI
  local REPO_REF
  local REPO_FETCH_DEPTH
  local REPO_SPARSE_PATH
  local REPO_SPARSE_PATH_STREAM
  local -a REPO_SPARSE_PATHS_ARR
  local -a GIT_ARGS_ARR

  PIPELINE_NAME="$1"
  TEMP_WORKSPACE_DIR="$2"
  BARE_REPO_URI="$3"
  REPO_REF="$4"

  REPO_FETCH_DEPTH="$(
    jqw -r \
      --arg 'p' "$PIPELINE_NAME" \
      --argfile 'schema' "$INSTALL_DIR/schema/ci_config_schema-v$CI_CONFIG_SCHEMA_VERSION.json" \
      '$schema.definitions.repository.properties.fetch_depth.default as $default
       | .pipelines[] | select(.name == $p) | .repository.fetch_depth // $default
      ' \
      <<< "$CI_CONFIG"
  )"

  REPO_SPARSE_PATH_STREAM="$(
    jqw -c \
      --arg 'p' "$PIPELINE_NAME" \
      --argfile 'schema' "$INSTALL_DIR/schema/ci_config_schema-v$CI_CONFIG_SCHEMA_VERSION.json" \
      '$schema.definitions.repository.properties.sparse_paths.default as $default
       | .pipelines[] | select(.name == $p) | .repository.sparse_paths // $default | .[]
      ' \
      <<< "$CI_CONFIG"
  )"

  REPO_SPARSE_PATHS_ARR=()
  while IFS= read -r REPO_SPARSE_PATH; do
    [[ -z "$REPO_SPARSE_PATH" ]] && continue
    REPO_SPARSE_PATHS_ARR+=("$(jqw -rj '.' <<< "$REPO_SPARSE_PATH")")
  done <<< "$REPO_SPARSE_PATH_STREAM"

  GIT_ARGS_ARR=(
    --branch "$REPO_REF"
    --single-branch
    -c advice.detachedHead=false
  )

  if (( REPO_FETCH_DEPTH > 0 )); then
    GIT_ARGS_ARR+=(
      --depth "$REPO_FETCH_DEPTH"
    )
  fi

  if (( ${#REPO_SPARSE_PATHS_ARR[@]} )); then
    GIT_ARGS_ARR+=(
      --filter="blob:none"
      --sparse
      --no-checkout
    )
  fi

  if [[ ! "$BARE_REPO_URI" =~ ^(file|http|https|ssh):// ]]; then
    log -m "pipeline=$PIPELINE_NAME" ERROR 'Cloning requires an explicit URI (file, http(s), ssh); Got: %s' \
      "$BARE_REPO_URI"
    return 1
  fi

  log -m "pipeline=$PIPELINE_NAME" INFO 'Cloning %s from repository %s' "$REPO_REF" "$BARE_REPO_URI"
  if ! git clone "${GIT_ARGS_ARR[@]}" "$BARE_REPO_URI" "$TEMP_WORKSPACE_DIR"; then
    log -m "pipeline=$PIPELINE_NAME" ERROR 'Failed to clone ref %s on %s' "$REPO_REF" "$BARE_REPO_URI"
    return 6
  fi

  if (( ${#REPO_SPARSE_PATHS_ARR[@]} )); then
    log -m "pipeline=$PIPELINE_NAME" INFO 'Applying sparse-checkout in clone of repository %s' "$BARE_REPO_URI"
    git -C "$TEMP_WORKSPACE_DIR" sparse-checkout init --cone --sparse-index
    git -C "$TEMP_WORKSPACE_DIR" sparse-checkout set "${REPO_SPARSE_PATHS_ARR[@]}"
    git -C "$TEMP_WORKSPACE_DIR" checkout "$REPO_REF"
  fi
}

function prepare_workspace {

  local PIPELINE_NAME
  local TEMP_WORKSPACE_DIR
  local WORKSPACE_DIR

  PIPELINE_NAME="$1"
  TEMP_WORKSPACE_DIR="$2"

  WORKSPACE_DIR="$(
    jqw -r --arg 'p' "$PIPELINE_NAME" \
      '.pipelines[] | select(.name == $p) | .latest_execution.workspace_dir' \
      "$STATE_FILE"
  )"

  if [[ -z "$WORKSPACE_DIR" ]]; then
    log -m "pipeline=$PIPELINE_NAME" ERROR 'Cannot proceed with undefined workspace directory'
    return 1
  fi

  # remove existing deployment directory to ensure a clean state
  if [[ -d "$WORKSPACE_DIR" ]]; then
    log -m "pipeline=$PIPELINE_NAME" WARNING 'Removing existing workspace directory %s' "$WORKSPACE_DIR"
    rm -rf "$WORKSPACE_DIR"
  fi

  mkdir -p "$(dirname "$WORKSPACE_DIR")"
  mv "$TEMP_WORKSPACE_DIR" "$WORKSPACE_DIR"
}

function teardown {

  if [[ -n "${CG_JOBS_DIR:-}" ]]; then
    cgroupctl gracefully-terminate "$CG_JOBS_DIR"
    cgroupctl force-terminate "$CG_JOBS_DIR" 30
    cgroupctl destroy "$CG_JOBS_DIR"
  fi

  if [[ -n "${CG_ENGINE_ROOT_DIR:-}" ]]; then
    cgroupctl destroy "$CG_ENGINE_ROOT_DIR"
  fi

  if [[ -n "${TEMP_DIR:-}" && -d "$TEMP_DIR" ]]; then
    rm -rf "$TEMP_DIR"
  fi
}

function error_trap {

  log ERROR 'The script stopped due to unexpected return code %d at line %d' "$2" "$1"
  teardown
  exit 5
}

function interrupt_trap {

  log WARNING 'The script was interrupted by signal at line %d' "$1"
  teardown
  exit 4
}

function setup_signal_handling {

  trap 'error_trap "$LINENO" "$?"' ERR
  trap 'interrupt_trap "$LINENO"' INT
}

function setup_std_stream_logging {

  [[ ${LOG_STREAM_ACTIVE:-0} -eq 1 ]] && return
  LOG_STREAM_ACTIVE=1

  exec {ORIG_OUT}>&1 {ORIG_ERR}>&2
  export ORIG_OUT ORIG_ERR LOG_STREAM_ACTIVE=1

  exec 1> >(stdbuf -oL log --stream INFO || true)
  exec 2> >(stdbuf -oL log --stream WARNING || true)
}

# only perform if the script is executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -euo pipefail
  setup_signal_handling
  main "$@"
  exit 0
fi
