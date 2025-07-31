#!/usr/bin/env bash

function test_spec {

  export TEST_DIR="$1"
  export TEST_NAME="$(basename "$TEST_DIR")"
  TEST_PARTS_FAILED=0

  setup_signal_handling
  set_env_defaults
  create_temp_dir

  function spawn_until_term {
    # blocks until it receives SIGTERM, then exits 0
    bash -c 'trap "exit 0" TERM; while :; do sleep 1; done' &
  }

  function spawn_ignore_term {
    # ignores SIGTERM (and INT/HUP); will not exit on graceful terminate
    bash -c 'trap "" TERM; trap "" INT HUP; while :; do sleep 1; done' &
  }

  it "must reject path outside mount point with exit 1"
  PARENT_CG_DIR="$(mktemp -d "$TEMP_DIR/foo-XXXXXXXX")"
  expect_exit_code 1 -- cgroupctl create "$PARENT_CG_DIR" 'cgroupctl_test'

  it "should create inner nodes under root node"
  create_cgroup_nodes
  assert_exists "$CG_ENGINE_ROOT_DIR"
  assert_exists "$CG_ENGINE_DIR"
  assert_exists "$CG_JOBS_DIR"

  it "should create sub cgroups"
  CG_SUB_A_DIR="$(cgroupctl create "$CG_JOBS_DIR" 'cgroupctl_test_sub' 1)"
  CG_SUB_B_DIR="$(cgroupctl create "$CG_JOBS_DIR" 'cgroupctl_test_sub' 1)"
  assert_exists "$CG_SUB_A_DIR"
  assert_exists "$CG_SUB_B_DIR"

  it "should move processes to sub cgroups"
  spawn_until_term; PID_SUB_1=$!
  spawn_until_term; PID_SUB_2=$!
  spawn_until_term; PID_SUB_3=$!
  spawn_ignore_term; PID_SUB_4=$!
  cgroupctl attach "$CG_SUB_A_DIR" "$PID_SUB_1"
  cgroupctl attach "$CG_SUB_A_DIR" "$PID_SUB_2"
  cgroupctl attach "$CG_SUB_B_DIR" "$PID_SUB_3"
  cgroupctl attach "$CG_SUB_B_DIR" "$PID_SUB_4"
  assert_file_contains "$CG_SUB_A_DIR/cgroup.procs" "$PID_SUB_1"
  assert_file_contains "$CG_SUB_A_DIR/cgroup.procs" "$PID_SUB_2"
  assert_file_contains "$CG_SUB_B_DIR/cgroup.procs" "$PID_SUB_3"
  assert_file_contains "$CG_SUB_B_DIR/cgroup.procs" "$PID_SUB_4"

  it "should write memory.max for hard limit"
  cgroupctl set-memory-hard-limit "$CG_SUB_A_DIR" "10M"
  assert_file_equals "$CG_SUB_A_DIR/memory.max" "10485760"

  it "should write memory.high for soft limit"
  cgroupctl set-memory-soft-limit "$CG_SUB_A_DIR" "8M"
  assert_file_equals "$CG_SUB_A_DIR/memory.high" "8388608"

  it "should compute CPU quota for MODE=all"
  cgroupctl set-cpu-limit "$CG_SUB_A_DIR" "0.25" "all"
  PERIOD="$(awk '{print $2}' "$CG_SUB_A_DIR/cpu.max" || echo "100000")"
  CORES_COUNT="$(getconf _NPROCESSORS_ONLN)"
  QUOTA="$(awk -v p="$PERIOD" -v c="$CORES_COUNT" 'BEGIN { printf("%d", 0.25 * p * c) }')"
  assert_file_equals "$CG_SUB_A_DIR/cpu.max" "$QUOTA $PERIOD"

  it "must set 'max' for MODE=all with LIMIT=1"
  cgroupctl set-cpu-limit "$CG_SUB_B_DIR" "1.0" "all"
  assert_file_equals "$CG_SUB_B_DIR/cpu.max" "max 100000"

  it "should compute CPU quota for MODE=one"
  cgroupctl set-cpu-limit "$CG_SUB_B_DIR" "0.25" "one"
  QUOTA="$(awk -v p="$PERIOD" 'BEGIN { printf("%d", 0.25 * p) }')"
  assert_file_equals "$CG_SUB_B_DIR/cpu.max" "$QUOTA $PERIOD"

  it "assumes that 100 is the default CPU weight"
  assert_file_equals "$CG_SUB_A_DIR/cpu.weight" "100"

  it "must clamp CPU weight: 0.0 -> 1"
  cgroupctl set-cpu-weight "$CG_SUB_A_DIR" "0"
  assert_file_equals "$CG_SUB_A_DIR/cpu.weight" "1"

  it "must clamp CPU weight: 1.5 -> 10000"
  cgroupctl set-cpu-weight "$CG_SUB_A_DIR" "1.5"
  assert_file_equals "$CG_SUB_A_DIR/cpu.weight" "10000"

  it "should set CPU weight"
  cgroupctl set-cpu-weight "$CG_SUB_A_DIR" "0.057"
  assert_file_equals "$CG_SUB_A_DIR/cpu.weight" "570"

  it "should gracefully terminate with TERM signal"
  cgroupctl gracefully-terminate "$CG_SUB_A_DIR"
  cgroupctl wait-processes "$CG_SUB_A_DIR" 3

  it "must NOT terminate gracefully on SIGTERM ignoring tasks"
  cgroupctl gracefully-terminate "$CG_SUB_B_DIR"
  expect_exit_code 1 -- cgroupctl wait-processes "$CG_SUB_B_DIR" 3

  it "should forced terminate on SIGTERM ignoring tasks"
  cgroupctl force-terminate "$CG_SUB_B_DIR"
  cgroupctl wait-processes "$CG_SUB_B_DIR" 3

  it "should destroy leaf nodes when empty"
  cgroupctl destroy "$CG_SUB_A_DIR" 3
  cgroupctl destroy "$CG_SUB_B_DIR" 3
  assert_not_exists "$CG_SUB_A_DIR"
  assert_not_exists "$CG_SUB_B_DIR"

  it "should destroy inner cgroup nodes when empty"
  teardown
  assert_not_exists "$CG_ENGINE_ROOT_DIR"
  assert_not_exists "$CG_ENGINE_DIR"
  assert_not_exists "$CG_JOBS_DIR"

  return $(( TEST_PARTS_FAILED > 0 ? 1 : 0 ))
}

function cgroupctl {

  "$INSTALL_DIR/lib/cgroupctl.sh" "$@"
}
