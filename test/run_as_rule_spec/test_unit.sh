#!/usr/bin/env bash

function build_setpriv_args {

  local PIPELINE_NAME
  local JOB_NAME

  local PIPELINE_NAME="$1"
  local JOB_NAME="$2"

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
}

function build_passwd_and_group_data {

  CURRENT_UID="1001"  # bob
  CURRENT_GID="100"   # users

  PASSWD_LIST='
root:x:0:0:root:/root:/bin/sh
alice:x:1000:100:Alice:/home/alice:/bin/bash
bob:x:1001:100:Bob:/home/bob:/bin/bash
builder:x:2000:200:Builder:/home/builder:/bin/bash
'

  GROUP_LIST='
root:x:0:
users:x:100:
devs:x:200:
staff:x:300:
dialout:x:20:
'
}

function test_spec {

  export TEST_DIR="$1"
  export TEST_NAME="$(basename "$TEST_DIR")"
  TEST_PARTS_FAILED=0

  CI_CONFIG_FILE="$TEST_DIR/ci.yaml"

  set_env_defaults
  load_ci_config
  build_passwd_and_group_data

  # 1) No run_as → defaults (CURRENT_UID/GID + --init-groups)
  it "uses default UID/GID and --init-groups when run_as is missing"
  ACTUAL="$(build_setpriv_args "p_run_as" "job_default")"
  EXPECTED='[ "--reuid", "1001", "--regid", "100", "--init-groups" ]'
  assert_json_eq "$EXPECTED" "$ACTUAL" "args for job_default"

  # 2) group: explicit null values → defaults (CURRENT_UID/GID + --init-groups)
  it "treats explicit null values for user, group, supplementary_groups with default UID/GID and --init-groups"
  ACTUAL="$(build_setpriv_args "p_run_as" "job_null_values")"
  EXPECTED='[ "--reuid", "1001", "--regid", "100", "--init-groups" ]'
  assert_json_eq "$EXPECTED" "$ACTUAL" "args for job_null_values"

  # 3) user as name → UID/GID from passwd, group null → user’s primary group
  it "resolves user by name (UID/GID from passwd) and sets --init-groups"
  ACTUAL="$(build_setpriv_args "p_run_as" "job_user_name")"
  EXPECTED='[ "--reuid", "1000", "--regid", "100", "--init-groups" ]'
  assert_json_eq "$EXPECTED" "$ACTUAL" "args for job_user_name"

  # 4) user as UID → UID/GID from passwd
  it "resolves user by numeric UID and sets primary group and --init-groups"
  ACTUAL="$(build_setpriv_args "p_run_as" "job_user_uid")"
  EXPECTED='[ "--reuid", "2000", "--regid", "200", "--init-groups" ]'
  assert_json_eq "$EXPECTED" "$ACTUAL" "args for job_user_uid"

  # 5) user + group by name → GID from group, not from passwd
  it "overrides primary group with group by name"
  ACTUAL="$(build_setpriv_args "p_run_as" "job_user_and_group_name")"
  EXPECTED='[ "--reuid", "1000", "--regid", "300", "--init-groups" ]'
  assert_json_eq "$EXPECTED" "$ACTUAL" "args for job_user_and_group_name"

  # 6) user + group as GID
  it "overrides primary group with group by numeric GID"
  ACTUAL="$(build_setpriv_args "p_run_as" "job_user_and_group_gid")"
  EXPECTED='[ "--reuid", "2000", "--regid", "100", "--init-groups" ]'
  assert_json_eq "$EXPECTED" "$ACTUAL" "args for job_user_and_group_gid"

  # 7) user root by name → 0:0
  it "resolves root by name to 0:0 with --init-groups"
  ACTUAL="$(build_setpriv_args "p_run_as" "job_user_root_name")"
  EXPECTED='[ "--reuid", "0", "--regid", "0", "--init-groups" ]'
  assert_json_eq "$EXPECTED" "$ACTUAL" "args for job_user_root_name"

  # 8) user root by UID → 0:0
  it "resolves root by uid 0 to 0:0 with --init-groups"
  ACTUAL="$(build_setpriv_args "p_run_as" "job_user_root_uid")"
  EXPECTED='[ "--reuid", "0", "--regid", "0", "--init-groups" ]'
  assert_json_eq "$EXPECTED" "$ACTUAL" "args for job_user_root_uid"

  # 9) supplementary_groups = [] (empty) → neither --init-groups nor --groups
  it "omits --init-groups/--groups for empty supplementary_groups"
  ACTUAL="$(build_setpriv_args "p_run_as" "job_supp_groups_empty")"
  EXPECTED='[ "--reuid", "1000", "--regid", "100" ]'
  assert_json_eq "$EXPECTED" "$ACTUAL" "args for job_supp_groups_empty"

  # 10) supplementary_groups = ["devs", "dialout"] → --groups "200,20"
  it "sets --groups for non-empty supplementary_groups (names)"
  ACTUAL="$(build_setpriv_args "p_run_as" "job_supp_groups_names")"
  EXPECTED='[ "--reuid", "1000", "--regid", "100", "--groups", "200,20" ]'
  assert_json_eq "$EXPECTED" "$ACTUAL" "args for job_supp_groups_names"

  # 11) supplementary_groups mixed (name + GID)
  it "sets --groups for mixed supplementary_groups (names + GIDs)"
  ACTUAL="$(build_setpriv_args "p_run_as" "job_supp_groups_mixed")"
  EXPECTED='[ "--reuid", "1000", "--regid", "100", "--groups", "200,300,100" ]'
  assert_json_eq "$EXPECTED" "$ACTUAL" "args for job_supp_groups_mixed"

  # 12) allow_privilege_escalation=false → --no-new-privs
  it "appends --no-new-privs when allow_privilege_escalation=false"
  ACTUAL="$(build_setpriv_args "p_run_as" "job_no_new_privs")"
  EXPECTED='[ "--reuid", "2000", "--regid", "200", "--init-groups", "--no-new-privs" ]'
  assert_json_eq "$EXPECTED" "$ACTUAL" "args for job_no_new_privs"

  # 13) Error: unknown user by name
  it "fails when user is unknown (by name)"
  expect_exit_code 5 -- build_setpriv_args "p_run_as" "job_user_name_unknown"

  # 14) Error: unknown user by UID
  it "fails when user is unknown (by numeric UID)"
  expect_exit_code 5 -- build_setpriv_args "p_run_as" "job_user_uid_unknown"

  # 15) Error: unknown group by name (primary group)
  it "fails when primary group is unknown (by name)"
  expect_exit_code 5 -- build_setpriv_args "p_run_as" "job_group_name_unknown"

  # 16) Error: unknown group by GID (primary group)
  it "fails when primary group is unknown (by numeric GID)"
  expect_exit_code 5 -- build_setpriv_args "p_run_as" "job_group_gid_unknown"

  # 17) Error: unknown supplementary_group in list
  it "fails when a supplementary group is unknown (by name)"
  expect_exit_code 5 -- build_setpriv_args "p_run_as" "job_supp_groups_unknown"

  return $(( TEST_PARTS_FAILED > 0 ? 1 : 0 ))
}
