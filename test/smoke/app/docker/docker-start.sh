#!/bin/bash

set -euo pipefail

SOCK=/opt/app/run/fcgiwrap.sock
PID=/opt/app/run/nginx.pid
rm -f "$SOCK" "$PID"
spawn-fcgi -s "$SOCK" -M 660 -- /usr/sbin/fcgiwrap
exec nginx -g 'daemon off;' -c /opt/app/conf/nginx.conf
