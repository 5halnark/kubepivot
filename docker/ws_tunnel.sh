#!/usr/bin/env bash
set -euo pipefail

LISTEN_TARGET="$1"   # e.g. 127.0.0.1:2222  (what the tunnel is allowed to reach)
WS_PORT="$2"         # e.g. 30000           (local ws backend port)

# Supervise: restart the ws backend if it ever exits.
while true; do
  echo "[wstunnel] server ws://127.0.0.1:${WS_PORT} -> ${LISTEN_TARGET}"
  wstunnel server "ws://127.0.0.1:${WS_PORT}" --restrict-to "${LISTEN_TARGET}" || true
  echo "[wstunnel] exited, restarting in 1s..."
  sleep 1
done
