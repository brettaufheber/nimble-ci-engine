#!/usr/bin/env bash

function test_setup {

  mkdir -p "$TEST_RESOURCES_DIR"

  printf 'ABSOLUTE OK' > "$TEST_RESOURCES_DIR/file_abs.txt"
  printf 'RELATIVE OK' > "$TEST_RESOURCES_DIR/file_rel.txt"
  printf 'SPACE OK' > "$TEST_RESOURCES_DIR/file with space.txt"
  printf 'HTTP OK' > "$TEST_RESOURCES_DIR/http.txt"
  printf 'SFTP OK' > "$TEST_RESOURCES_DIR/sftp.txt"

    cat > "$CI_RESULT_FILE" <<EOF
{
  "variables": {
    "FILE_ABS": "ABSOLUTE OK",
    "FILE_REL": "RELATIVE OK",
    "FILE_SPACE": "SPACE OK",
    "HTTP_FILE": "HTTP OK",
    "SFTP_SSH_HOME": "$TEST_RESOURCES_DIR",
    "SFTP_FILE": "SFTP OK"
  },
  "pipelines": []
}
EOF

  # make sure the Docker containers are stopped and removed
  test_teardown

  SERVICE_HOST="${SERVICE_HOST:-"localhost"}"
  DOCKER_REGISTRY="${DOCKER_REGISTRY:-"docker.io"}"
  TEST_HTTP_SRV_IMAGE="${TEST_HTTP_SRV_IMAGE:-"$DOCKER_REGISTRY/nginx:latest"}"
  TEST_SFTP_SRV_IMAGE="${TEST_SFTP_SRV_IMAGE:-"$DOCKER_REGISTRY/atmoz/sftp:latest"}"
  TEST_HTTP_SRV_PORT="${TEST_HTTP_SRV_PORT:-"18080"}"
  TEST_SFTP_SRV_PORT="${TEST_SFTP_SRV_PORT:-"12222"}"
  SFTP_USERNAME="foo"
  SFTP_PASSWORD="bar"

  # make these variables available in the ci.yaml file
  export HTTP_AUTHORITY="$SERVICE_HOST:$TEST_HTTP_SRV_PORT"
  export SFTP_AUTHORITY="$SFTP_USERNAME:$SFTP_PASSWORD@$SERVICE_HOST:$TEST_SFTP_SRV_PORT"

  docker run \
    --name "$HTTP_CONTAINER_NAME" \
    --detach \
    -p "$TEST_HTTP_SRV_PORT:80" \
    -v "$TEST_RESOURCES_DIR:/usr/share/nginx/html:ro" \
    "$TEST_HTTP_SRV_IMAGE"

  docker run \
    --name "$SFTP_CONTAINER_NAME" \
    --detach \
    -p "$TEST_SFTP_SRV_PORT:22" \
    -v "$TEST_RESOURCES_DIR:/home/$SFTP_USERNAME/upload:ro" \
    "$TEST_SFTP_SRV_IMAGE" "$SFTP_USERNAME:$SFTP_PASSWORD"

  mkdir -p "$TEST_RESOURCES_DIR/.ssh"

  DEADLINE="$((SECONDS+30))"
  until ssh-keyscan -4 -T 1 -p "$TEST_SFTP_SRV_PORT" "$SERVICE_HOST" 2>/dev/null \
      | awk -v h="$SERVICE_HOST" -v p="$TEST_SFTP_SRV_PORT" 'BEGIN{OFS=" "} $1!~/^#/ { $1="[" h "]:" p; print }' \
      > "$TEST_RESOURCES_DIR/.ssh/known_hosts" && [[ -s "$TEST_RESOURCES_DIR/.ssh/known_hosts" ]]; do
    if (( SECONDS >= DEADLINE )); then
      log ERROR 'Timeout: SSH on %s:%d did not come up in time' "$SERVICE_HOST" "$TEST_SFTP_SRV_PORT"
      exit 1
    fi
    sleep 1
  done

  (
    export CONNECTION_TIMEOUT_SECONDS=2
    export DOWNLOAD_TIMEOUT_SECONDS=10
    export SFTP_SSH_HOME="$TEST_RESOURCES_DIR"

    DEADLINE="$((SECONDS+30))"
    until "$INSTALL_DIR/extensions/uri_resolvers/curl.sh" "sftp://$SFTP_AUTHORITY/upload/sftp.txt" &> /dev/null &&
        "$INSTALL_DIR/extensions/uri_resolvers/curl.sh" "http://$HTTP_AUTHORITY/http.txt" &> /dev/null; do
      if (( SECONDS >= DEADLINE )); then
        log ERROR 'Timeout: Test supporting services did not come up in time'
        exit 1
      fi
      sleep 1
    done
  )
}

function test_teardown {

  docker rm -f "$HTTP_CONTAINER_NAME" &> /dev/null || true
  docker rm -f "$SFTP_CONTAINER_NAME" &> /dev/null || true
}

function test_spec {

  export TEST_DIR="$1"
  export TEST_NAME="$(basename "$TEST_DIR")"

  set_env_defaults
  create_temp_dir

  # make these variables available in the ci.yaml file
  export TEST_RESOURCES_DIR="$TEMP_DIR/$TEST_NAME"
  export TEST_REL_PATH_RESOURCES_DIR="$(realpath --relative-to="$INSTALL_DIR" "$TEST_RESOURCES_DIR")"

  CI_CONFIG_FILE="$TEST_DIR/ci.yaml"  # this variable is required by the CI engine
  CI_RESULT_FILE="$TEST_RESOURCES_DIR/result.json"
  HTTP_CONTAINER_NAME="ci_engine_uri_test_http"
  SFTP_CONTAINER_NAME="ci_engine_uri_test_sftp"

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

  log INFO 'Success: All URIs are resolved'

  test_teardown
  teardown
}
