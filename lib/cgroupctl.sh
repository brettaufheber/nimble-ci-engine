#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025 Eric Löffler <eric.loeffler@opalia.systems>
# SPDX-License-Identifier: GPL-3.0-or-later

function main {

  # ensure root privileges
  if [[ "$EUID" -ne 0 ]]; then
    log ERROR 'Require root privileges'
    return 2
  fi

  # ensure a command is given
  if [[ $# -lt 1 ]]; then
    log ERROR 'No command specified'
    print_usage
    return 1
  fi

  local CMD="$1"
  shift

  case "$CMD" in
    mount-point)
      [[ $# -eq 0 ]] || { print_usage; return 1; }
      cmd_mount_point
      ;;
    create)
      [[ $# -eq 2 || $# -eq 3 ]] || { print_usage; return 1; }
      cmd_create "$@"
      ;;
    attach)
      [[ $# -eq 2 ]] || { print_usage; return 1; }
      validate_cgroup_dir "$1"
      cmd_attach "$@"
      ;;
    set-memory-hard-limit)
      [[ $# -eq 2 ]] || { print_usage; return 1; }
      validate_cgroup_dir "$1"
      cmd_set_memory_hard_limit "$@"
      ;;
    set-memory-soft-limit)
      [[ $# -eq 2 ]] || { print_usage; return 1; }
      validate_cgroup_dir "$1"
      cmd_set_memory_soft_limit "$@"
      ;;
    set-cpu-limit)
      [[ $# -eq 2 || $# -eq 3 ]] || { print_usage; return 1; }
      validate_cgroup_dir "$1"
      cmd_set_cpu_limit "$@"
      ;;
    set-cpu-weight)
      [[ $# -eq 2 ]] || { print_usage; return 1; }
      validate_cgroup_dir "$1"
      cmd_set_cpu_weight "$@"
      ;;
    gracefully-terminate)
      [[ $# -eq 1 ]] || { print_usage; return 1; }
      validate_cgroup_dir "$1"
      cmd_gracefully_terminate "$@"
      ;;
    force-terminate)
      [[ $# -eq 1 || $# -eq 2 ]] || { print_usage; return 1; }
      validate_cgroup_dir "$1"
      cmd_force_terminate "$@"
      ;;
    destroy)
      [[ $# -eq 1 || $# -eq 2 ]] || { print_usage; return 1; }
      validate_cgroup_dir "$1"
      cmd_destroy "$@"
      ;;
    wait-processes)
      [[ $# -eq 1 || $# -eq 2 ]] || { print_usage; return 1; }
      validate_cgroup_dir "$1"
      cmd_wait_processes "$@"
      ;;
    help)
      [[ $# -eq 0 ]] || { print_usage; return 1; }
      print_usage
      ;;
    *)
      log ERROR 'Unknown command: %s' "$CMD"
      print_usage
      return 1
      ;;
  esac
}

function cmd_mount_point {

  local MOUNT_POINT

  # find the cgroup2 mount point
  MOUNT_POINT="$(grep -P '\s+-\s+cgroup2\s+' /proc/self/mountinfo | awk '{print $5; exit}')"
  if [[ -z "$MOUNT_POINT" ]]; then
    log ERROR 'Cannot find cgroup2 mount point'
    return 2
  fi

  echo "$MOUNT_POINT"
}

function cmd_create {

  local PARENT_CGROUP_DIR
  local CGROUP_DIR
  local MOUNT_POINT
  local PREFIX
  local OOM_GROUP_FLAG
  local CGROUP_CTRL

  PARENT_CGROUP_DIR="$1"
  PREFIX="$2"
  OOM_GROUP_FLAG="${3:-0}"
  MOUNT_POINT="$(cmd_mount_point)"

  if [[ "$PARENT_CGROUP_DIR" != "$MOUNT_POINT" ]]; then

    validate_cgroup_dir "$PARENT_CGROUP_DIR"

    # ensure required controllers are enabled for the subtree
    if [[ -r "$PARENT_CGROUP_DIR/cgroup.controllers" && -w "$PARENT_CGROUP_DIR/cgroup.subtree_control" ]]; then
      for CGROUP_CTRL in cpu memory; do
        echo "+$CGROUP_CTRL" > "$PARENT_CGROUP_DIR/cgroup.subtree_control" 2>/dev/null || true
      done
    fi
  fi

  # create a uniquely named cgroup directory under the given parent
  CGROUP_DIR="$(mktemp -d "$PARENT_CGROUP_DIR/$PREFIX-XXXXXXXX")"

  # set OOM group flag; if set the OOM kill affects the entire cgroup
  if [[ -w "$CGROUP_DIR/memory.oom.group" ]]; then
    echo "$OOM_GROUP_FLAG" > "$CGROUP_DIR/memory.oom.group"
  fi

  echo "$CGROUP_DIR"
}

function cmd_attach {

  local CGROUP_DIR
  local PID

  CGROUP_DIR="$1"
  PID="$2"

  # move the process into the cgroup
  echo "$PID" > "$CGROUP_DIR/cgroup.procs"
}

function cmd_set_memory_hard_limit {

  local CGROUP_DIR
  local LIMIT

  CGROUP_DIR="$1"
  LIMIT="$2"

  # enforce a hard memory cap; exceeding this triggers the OOM killer for the cgroup
  echo "$LIMIT" > "$CGROUP_DIR/memory.max"
}

function cmd_set_memory_soft_limit {

  local CGROUP_DIR
  local LIMIT

  CGROUP_DIR="$1"
  LIMIT="$2"

  # define a soft memory threshold: under memory pressure, pages above this are reclaimed first,
  # effectively throttling this cgroup before hitting the hard limit.
  echo "$LIMIT" > "$CGROUP_DIR/memory.high"
}

function cmd_set_cpu_limit {

  local CGROUP_DIR
  local LIMIT
  local QUOTA
  local PERIOD
  local CORES_COUNT
  local MODE

  CGROUP_DIR="$1"
  LIMIT="$2"
  MODE="${3:-all}"

  # read existing CPU period (fallback to 100000 if unavailable)
  PERIOD="$(awk '{print $2}' "$CGROUP_DIR/cpu.max" || echo '100000')"

  # determine number of CPU cores
  CORES_COUNT="$(getconf _NPROCESSORS_ONLN)"

  # calculate CPU quota based on desired vCPU fraction, period, and core count
  case "$MODE" in
    one)
      # LIMIT applies per CPU: quota = limit * period
      QUOTA="$(
        LC_NUMERIC=C awk \
          -v limit="$LIMIT" \
          -v period="$PERIOD" \
          '
            BEGIN {
              quota = limit * period
              if (quota < 1000) quota = 1000
              printf("%.0f", quota)
            }
          '
      )"
      ;;
    all)
      # LIMIT applies across all CPUs: quota = limit * period * number_of_cores
      QUOTA="$(
        LC_NUMERIC=C awk \
          -v limit="$LIMIT" \
          -v period="$PERIOD" \
          -v number_of_cores="$CORES_COUNT" \
          '
            BEGIN {
              if (limit >= 1) { print "max"; exit }
              quota = limit * period * number_of_cores
              if (quota < 1000) quota = 1000
              printf("%.0f", quota)
            }
          '
      )"
      ;;
    *)
      log ERROR 'Unknown CPU mode %s (allowed values: one | all)' "$MODE"
      return 1
      ;;
  esac

  # apply the calculated CPU quota and period to the cgroup
  echo "$QUOTA $PERIOD" > "$CGROUP_DIR/cpu.max"
}

function cmd_set_cpu_weight {

  local CGROUP_DIR
  local WEIGHT_RAW
  local WEIGHT

  CGROUP_DIR="$1"
  WEIGHT_RAW="$2"

  # calculate weight value [1..10000]
  WEIGHT="$(
    LC_NUMERIC=C awk -v weight_raw="$WEIGHT_RAW" \
    '
      BEGIN {
        weight = weight_raw * 10000
        if (weight < 1) weight = 1
        if (weight > 10000) weight = 10000;
        printf("%.0f", weight)
      }
    '
  )"

  # apply the calculated weight value to the cgroup
  echo "$WEIGHT" > "$CGROUP_DIR/cpu.weight"
}

function cmd_gracefully_terminate {

  local CGROUP_DIR
  local PROCS
  local PID

  CGROUP_DIR="$1"

  # freeze entire cgroup subtree to avoid PID reuse/races
  if [[ -w "$CGROUP_DIR/cgroup.freeze" ]]; then
    echo 1 > "$CGROUP_DIR/cgroup.freeze"
    # wait until the kernel confirms the freeze
    while ! grep -qP '^frozen\s+1$' "$CGROUP_DIR/cgroup.events"; do
      sleep 0.1
    done
  fi

  # queue SIGTERM for all current tasks in the cgroup subtree (delivered after unfreeze)
  find -P "$CGROUP_DIR" -ignore_readdir_race -type f -name "cgroup.procs" -print0 |
    while IFS= read -r -d '' PROCS; do
      while IFS= read -r PID; do
        kill -TERM "$PID" 2>/dev/null || true
      done < "$PROCS"
    done

  # unfreeze so tasks can handle SIGTERM
  if [[ -w "$CGROUP_DIR/cgroup.freeze" ]]; then
    echo 0 > "$CGROUP_DIR/cgroup.freeze"
  fi
}

function cmd_force_terminate {

  local CGROUP_DIR
  local TIMEOUT
  local DEADLINE

  CGROUP_DIR="$1"
  TIMEOUT="${2:-0}"

  if (( TIMEOUT > 0 )); then
    DEADLINE="$(( SECONDS + TIMEOUT ))"
    until grep -qP '^populated\s+0$' "$CGROUP_DIR/cgroup.events"; do
      if (( SECONDS >= DEADLINE )); then
        break
      fi
      sleep 0.1
    done
  fi

  # immediately force-kill all tasks in the cgroup (SIGKILL)
  echo 1 > "$CGROUP_DIR/cgroup.kill"
}

function cmd_destroy {

  local CGROUP_DIR
  local TIMEOUT
  local DEADLINE
  local CHILD

  CGROUP_DIR="$1"
  TIMEOUT="${2:-0}"
  DEADLINE="$(( SECONDS + TIMEOUT ))"

  find -P "$CGROUP_DIR" -ignore_readdir_race -mindepth 1 -maxdepth 1 -type d -print0 |
    while IFS= read -r -d '' CHILD; do
      cmd_destroy "$CHILD" "$TIMEOUT" || true
    done

  cmd_wait_processes "$CGROUP_DIR" "$TIMEOUT"

  # wait until the cgroup is no longer in use, then remove it
  while [[ -d "$CGROUP_DIR" ]] && ! rmdir "$CGROUP_DIR" 2>/dev/null; do
    if (( TIMEOUT > 0 && SECONDS >= DEADLINE )); then
      log ERROR 'Timeout after %s seconds – cgroup %s not empty' "$TIMEOUT" "$CGROUP_DIR"
      return 1
    fi
    sleep 0.1
  done
}

function cmd_wait_processes {

  local CGROUP_DIR
  local TIMEOUT
  local DEADLINE

  CGROUP_DIR="$1"
  TIMEOUT="${2:-0}"

  # wait until the cgroup has no more tasks
  DEADLINE="$(( SECONDS + TIMEOUT ))"
  until grep -qP '^populated\s+0$' "$CGROUP_DIR/cgroup.events"; do
    if (( TIMEOUT > 0 && SECONDS >= DEADLINE )); then
      log ERROR 'Timeout after %s seconds – cgroup %s is still populated' "$TIMEOUT" "$CGROUP_DIR"
      return 1
    fi
    sleep 0.1
  done
}

function validate_cgroup_dir {

  local CGROUP_DIR
  local MOUNT_POINT
  local CGROUP_NORMALIZED_DIR

  CGROUP_DIR="$1"
  MOUNT_POINT="$(cmd_mount_point)"
  CGROUP_NORMALIZED_DIR="$(realpath -- "$CGROUP_DIR")"

  if [[ "$CGROUP_DIR" != "$CGROUP_NORMALIZED_DIR" ]]; then
   log ERROR 'The cgroup directory path is not normalized'
    return 1
  fi

  if [[ -z "$CGROUP_DIR" || ! -d "$CGROUP_DIR" ]]; then
   log ERROR 'The cgroup directory is invalid or does not exist'
    return 1
  fi

  if [[ "$CGROUP_DIR" == "$MOUNT_POINT" ]]; then
    log ERROR 'Refusing to operate on cgroup2 root mount point %s' "$MOUNT_POINT"
    return 1
  fi

  if [[ "$CGROUP_DIR" != "$MOUNT_POINT"/* ]]; then
    log ERROR 'The cgroup directory %s is not under mount point %s' "$CGROUP_DIR" "$MOUNT_POINT"
    return 1
  fi
}

function print_usage {
  cat <<EOF
Usage: ${0##*/} [COMMAND] [ARGS]

Commands:
  mount-point                                   Show the cgroup2 mount point
  create <PARENT> <PREFIX> [OOM_GROUP_FLAG]     Create a new cgroup under PARENT (OOM_GROUP_FLAG: 0 | 1)
  attach <CGDIR> <PID>                          Move PID into cgroup CGDIR
  set-memory-hard-limit <CGDIR> <BYTES>         Enforce a hard memory limit
  set-memory-soft-limit <CGDIR> <BYTES>         Set a soft memory threshold
  set-cpu-limit <CGDIR> <FLOAT> [MODE]          Limit CPU share (FLOAT: [0,1], MODE: one | all (default: all))
  set-cpu-weight <CGDIR> <FLOAT>                Set proportional CPU weight (FLOAT in [0,1])
  gracefully-terminate <CGDIR>                  Send SIGTERM to all tasks in cgroup subtree
  force-terminate <CGDIR> [TIMEOUT]             Immediately force-kill all tasks in cgroup subtree (TIMEOUT: seconds)
  destroy <CGDIR> [TIMEOUT]                     Remove the cgroup subtree once empty (TIMEOUT: seconds)
  wait-processes <CGDIR> [TIMEOUT]              Wait until all tasks in cgroup have exited (TIMEOUT: seconds)
  help                                          Show this help text
EOF
}

set -euo pipefail
main "$@"
exit 0
