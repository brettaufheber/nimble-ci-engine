#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025 Eric Löffler <eric.loeffler@opalia.systems>
# SPDX-License-Identifier: GPL-3.0-or-later

function main {

  local DEPENDENCY
  local OPTS

  set_defaults_step_1

  OPTS=$(
    getopt \
      -o '' \
      -l 'install-dir:,data-dir:,ci-config-file:,timer-interval:,boot-delay:,keep-previous-executions,local-only,no-timer,help' \
      -n "$(basename "$0")" -- "$@"
  )

  eval set -- "$OPTS"

  KEEP_PREVIOUS_EXECUTIONS=false
  LOCAL_ONLY=false
  SKIP_TIMER=false

  while true; do
    case "$1" in
      --install-dir)
        INSTALL_DIR="${2%/}"
        shift 2
        ;;
      --data-dir)
        DATA_DIR="$2"
        shift 2
        ;;
      --ci-config-file)
        CI_CONFIG_FILE="$2"
        shift 2
        ;;
      --timer-interval)
        TIMER_INTERVAL="$2"
        shift 2
        ;;
      --boot-delay)
        BOOT_DELAY="$2"
        shift 2
        ;;
      --keep-previous-executions)
        KEEP_PREVIOUS_EXECUTIONS=true
        shift 1
        ;;
      --local-only)
        LOCAL_ONLY=true
        shift 1
        ;;
      --no-timer)
        SKIP_TIMER=true
        shift 1
        ;;
      --help)
        print_usage
        exit 0
        ;;
      --)
        shift 1
        break
        ;;
      *)
        break
        ;;
    esac
  done

  if ! "$LOCAL_ONLY" && [[ "$EUID" -ne 0 ]]; then
    log ERROR 'Require root privileges'
    exit 2
  fi

  # Ensure Git and jq is installed
  for DEPENDENCY in git jq yq jsonschema trurl curl; do
    if ! command -v "$DEPENDENCY" &> /dev/null; then
      log ERROR 'Required command %s is not installed' "$DEPENDENCY"
      exit 1
    fi
  done

  set_defaults_step_2
  install_app
}

function set_defaults_step_1 {

  SCRIPT_FILE="$(readlink -f "$0")"
  SELF_DIR="$(dirname "$SCRIPT_FILE")"

  case ":$PATH:" in
    *":$SELF_DIR/lib:"*) ;;
    *) export PATH="$SELF_DIR/lib:$PATH" ;;
  esac

  APP_NAME="$(jqw -r '.name' "$SELF_DIR/build.json")"
  APP_NAME_ALTERNATIVE="$(sed -E 's/([a-z0-9])([A-Z])/\1-\2/g; s/[A-Z]/\L&/g' <<< "$APP_NAME")"
  APP_VERSION="$(jqw -r '.version' "$SELF_DIR/build.json")"
  APP_DESCRIPTION="$(jqw -r '.description' "$SELF_DIR/build.json")"
}

function set_defaults_step_2 {

  if [[ -n "${INSTALL_DIR:-}" ]]; then
    INSTALL_DIR="$(realpath "$INSTALL_DIR")"
  else
    INSTALL_DIR="/opt/$APP_NAME_ALTERNATIVE"
  fi

  if [[ -n "${DATA_DIR:-}" ]]; then
    DATA_DIR="$(realpath "$DATA_DIR")"
  else
    DATA_DIR="$INSTALL_DIR/data"
  fi

  if [[ -n "${CI_CONFIG_FILE:-}" ]]; then
    CI_CONFIG_FILE="$(realpath "$CI_CONFIG_FILE")"
  else
    CI_CONFIG_FILE="$INSTALL_DIR/config/ci.yaml"
  fi

  if [[ -z "${TIMER_INTERVAL:-}" ]]; then
    TIMER_INTERVAL="1min"
  fi

  if [[ -z "${BOOT_DELAY:-}" ]]; then
    BOOT_DELAY="1min"
  fi
}

function install_app {

  local ENV_FILE
  local SERVICE_FILE
  local TIMER_FILE
  local EXTENSION_DIR

  ENV_FILE="$INSTALL_DIR/config/.env"
  SERVICE_FILE="/etc/systemd/system/$APP_NAME_ALTERNATIVE.service"
  TIMER_FILE="/etc/systemd/system/$APP_NAME_ALTERNATIVE.timer"

  # copy all required files (only if INSTALL_DIR differs), overwriting if present
  if [[ "$INSTALL_DIR" != "$SELF_DIR" ]]; then
    mkdir -p "$INSTALL_DIR"
    cp -pf "$SELF_DIR/ci-run.sh" "$INSTALL_DIR/"
    cp -aTf "$SELF_DIR/lib" "$INSTALL_DIR/lib/"
    cp -aTf "$SELF_DIR/schema" "$INSTALL_DIR/schema/"
    cp -aTf "$SELF_DIR/scripts" "$INSTALL_DIR/scripts/"
    cp -aTf "$SELF_DIR/extensions" "$INSTALL_DIR/extensions/"
  fi

  while IFS= read -r -d '' EXTENSION_DIR; do
    if [[ -f "$EXTENSION_DIR/requirements.txt" ]]; then
      rm -rf "$EXTENSION_DIR/.venv"
      python3 -m venv "$EXTENSION_DIR/.venv" --upgrade-deps
      (
        cd "$EXTENSION_DIR"
        "$EXTENSION_DIR/.venv/bin/python" -Im pip install --upgrade -r "$EXTENSION_DIR/requirements.txt"
      )
    fi
  done < <(find "$INSTALL_DIR/extensions" -mindepth 2 -maxdepth 2 -type d -print0 || true)

  if ! "$LOCAL_ONLY"; then

    if [[ ! -f "$CI_CONFIG_FILE" ]]; then
      mkdir -p "$(dirname "$CI_CONFIG_FILE")"
      EXTENSION="${CI_CONFIG_FILE##*.}"
      if [[ "$EXTENSION" == 'yaml' || "$EXTENSION" == 'yml' ]]; then
        printf 'pipelines: []' > "$CI_CONFIG_FILE"
      elif [[ "$EXTENSION" == 'json' ]]; then
        printf '{ "pipelines": [] }' > "$CI_CONFIG_FILE"
      else
        log ERROR 'Unsupported config-file extension %s (must be .yaml/.yml or .json)' "$EXTENSION"
        exit 1
      fi
    fi

    mkdir -p "$(dirname "$ENV_FILE")"

    # create env file
    cat > "$ENV_FILE" <<EOF
CI_CONFIG_FILE="$CI_CONFIG_FILE"
STATE_FILE="$DATA_DIR/state.json"
STATE_LOCK_FILE="/var/lock/ci_engine/state.lock"
ENGINE_LOCK_FILE="/var/lock/ci_engine/engine.lock"
LOG_DIR="$DATA_DIR/logs"
DEFAULT_WORKSPACES_PARENT_DIR="$DATA_DIR/workspaces"
KEEP_PREVIOUS_EXECUTIONS="$KEEP_PREVIOUS_EXECUTIONS"
EOF

    # write systemd service
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=$APP_NAME: $APP_DESCRIPTION (v$APP_VERSION)
After=network.target local-fs.target

[Service]
Type=oneshot
WorkingDirectory=$INSTALL_DIR
EnvironmentFile=$ENV_FILE
ExecStart=$INSTALL_DIR/ci-run.sh
EOF

    # write systemd timer
    cat > "$TIMER_FILE" <<EOF
[Unit]
Description=Timer for $APP_NAME (v$APP_VERSION)

[Timer]
OnBootSec=$BOOT_DELAY
OnUnitActiveSec=$TIMER_INTERVAL
AccuracySec=1s
RandomizedDelaySec=0s

[Install]
WantedBy=timers.target
EOF

    # reload and enable
    systemctl daemon-reload
    if ! "$SKIP_TIMER"; then
      systemctl enable --now "$APP_NAME_ALTERNATIVE.timer"
    fi
  fi
}

function print_usage {
  cat <<EOF
Usage: ${0##*/} [OPTIONS]

--install-dir INSTALL_DIR               Installation directory (default: /opt/$APP_NAME_ALTERNATIVE)
--data-dir DATA_DIR                     Base output directory (default: INSTALL_DIR/data)
--ci-config-file CI_CONFIG_FILE         Path to CI file; can be YAML or JSON (default: INSTALL_DIR/config/ci.yaml)
--timer-interval TIMER_INTERVAL         Timer interval (e.g. 30s, 5min; default: 1min)
--boot-delay BOOT_DELAY                 Initial delay after boot (e.g. 10s, 2min; default: 1min)
--keep-previous-executions              Collect previous executions in state file
--no-service                            Do everything locally (no systemd files created, no root required)
--no-timer                              Do not enable the timer unit
--help                                  Show this help text and exit
EOF
}

set -euo pipefail
main "$@"
exit 0
