#!/usr/bin/env bash

set -euo pipefail

function main {

  case ":$PATH:" in
    *":$INSTALL_DIR/lib:"*) ;;
    *) export PATH="$INSTALL_DIR/lib:$PATH" ;;
  esac

  if [[ ! -f "$CI_CONFIG_FILE" ]]; then
    log ERROR 'Cannot find CI configuration file: %s' "$CI_CONFIG_FILE"
    exit 20
  fi

  if [[ ! -f "$STATE_FILE" ]]; then
    log ERROR 'Cannot find state file: %s' "$STATE_FILE"
    exit 21
  fi

  if [[ -n "${SLEEP:-}" ]]; then
    sleep "$SLEEP"
  fi

  verify_state_schema
  verify_concurrency_limits
  verify_needs

  log -m "pipeline=$CI_PIPELINE_NAME" -m "job=$CI_JOB_NAME" INFO 'All verifications passed'
}

function verify_state_schema {

  log -m "pipeline=$CI_PIPELINE_NAME" -m "job=$CI_JOB_NAME" INFO 'Validating state schema: %s' "$STATE_FILE"

  jsonschema \
    --base-uri "$SCHEMA_BASE_URI" \
    --instance "$STATE_FILE" \
    "$INSTALL_DIR/schema/state_schema.json" \
    >/dev/null

  log -m "pipeline=$CI_PIPELINE_NAME" -m "job=$CI_JOB_NAME" INFO 'State schema OK'
}

function verify_concurrency_limits {

  local ISSUES

  log -m "pipeline=$CI_PIPELINE_NAME" -m "job=$CI_JOB_NAME" \
    DEBUG 'Verifying concurrency limits (max_pipelines=%s, max_jobs_per_pipeline=%s)' \
    "$MAX_CONCURRENT_PIPELINES" "$MAX_CONCURRENT_JOBS_PER_PIPELINE"

  ISSUES="$(
    jqw -nc \
      --argjson 'mp' "$MAX_CONCURRENT_PIPELINES" \
      --argjson 'mj' "$MAX_CONCURRENT_JOBS_PER_PIPELINE" \
      --argfile 'state' "$STATE_FILE" \
      'include "lib/state_validation"; state_issues_concurrency_limits($state; $mp; $mj)'
  )"

  if [[ "$ISSUES" != "[]" ]]; then
    log -m "pipeline=$CI_PIPELINE_NAME" -m "job=$CI_JOB_NAME" \
      WARNING 'Concurrency limits verification failed — issues:\n%s' "$ISSUES"
    exit 22
  fi

  log -m "pipeline=$CI_PIPELINE_NAME" -m "job=$CI_JOB_NAME" INFO 'Concurrency limits OK'
}

function verify_needs {

  local ISSUES

  log -m "pipeline=$CI_PIPELINE_NAME" -m "job=$CI_JOB_NAME" \
    DEBUG 'Verifying non-parallel dependency order for current job'

  ISSUES="$(
    jqw -nc \
      --arg 'pipeline_name' "$CI_PIPELINE_NAME" \
      --arg 'job_name' "$CI_JOB_NAME" \
      --argfile 'config' "$CI_CONFIG_FILE" \
      --argfile 'state' "$STATE_FILE" \
      'include "lib/state_validation"; state_issues_needs_order($config; $state; $pipeline_name; $job_name)'
  )"

  if [[ "$ISSUES" != "[]" ]]; then
    log -m "pipeline=$CI_PIPELINE_NAME" -m "job=$CI_JOB_NAME" \
      WARNING 'Needs verification failed — blocking nodes running:\n%s' "$ISSUES"
    exit 23
  fi

  log -m "pipeline=$CI_PIPELINE_NAME" -m "job=$CI_JOB_NAME" INFO 'Needs OK'
}

set -euo pipefail
main "$@"
exit 0
