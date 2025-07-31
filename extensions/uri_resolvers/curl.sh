#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025 Eric Löffler <eric.loeffler@opalia.systems>
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

for DEPENDENCY in trurl curl; do
  if ! command -v "$DEPENDENCY" &> /dev/null; then
    log ERROR 'Required command %s is not installed' "$DEPENDENCY"
    exit 2
  fi
done

if [[ $# -ne 1 ]]; then
  log INFO 'Usage: %s <URI>' "${0##*/}"
  exit 1
fi

URI="$1"
SCHEME="${URI%%:*}"
CURL_OPTS=()

# timeouts via env variables
CURL_OPTS+=( --connect-timeout "${CONNECTION_TIMEOUT_SECONDS:-5}" )
CURL_OPTS+=( --max-time "${DOWNLOAD_TIMEOUT_SECONDS:-30}" )

# optional HTTP headers
if [[ ( "$SCHEME" == 'http' || "$SCHEME" == 'https' ) && -n "${HTTP_HEADERS:-}" ]]; then
  while IFS= read -r HEADER; do
    [[ -z "$HEADER" ]] && continue
    CURL_OPTS+=( --header "$HEADER" )
  done <<< "$HTTP_HEADERS"
fi

# optional SFTP parameters
if [[ "$SCHEME" == 'sftp' ]]; then
  if [[ -n "${SFTP_HOST_FINGERPRINT:-}" ]]; then
    CURL_OPTS+=( --hostpubsha256 "$SFTP_HOST_FINGERPRINT" )
  fi
  if [[ -n "${SFTP_PRIVATE_KEY_FILE:-}" ]]; then
    CURL_OPTS+=( --key "$SFTP_PRIVATE_KEY_FILE" )
  fi
  if [[ -n "${SFTP_PUBLIC_KEY_FILE:-}" ]]; then
    CURL_OPTS+=( --pubkey "$SFTP_PUBLIC_KEY_FILE" )
  fi
  if [[ -n "${SFTP_KEY_PASSPHRASE:-}" ]]; then
    CURL_OPTS+=( --pass "$SFTP_KEY_PASSPHRASE" )
  fi
fi

if [[ "$SCHEME" == 'sftp' && -n "${SFTP_SSH_HOME:-}" ]]; then
  if [[ ! -f "$SFTP_SSH_HOME/.ssh/known_hosts" ]]; then
    log WARNING 'Could not find file %s/.ssh/known_hosts' "$SFTP_SSH_HOME"
  fi
  export CURL_HOME="$SFTP_SSH_HOME"
fi

# normalize/encode relative/absolute file URIs
if [[ "$SCHEME" == 'file' ]]; then
  PATHSPEC="${URI#file:}"
  URI="$(
    trurl \
      --url "file://$PWD/" \
      --redirect "$PATHSPEC" \
      --no-guess-scheme \
      --accept-space \
      --urlencode \
      --get '{url}'
  )"
fi

curl -fsSL "${CURL_OPTS[@]}" "$URI"
