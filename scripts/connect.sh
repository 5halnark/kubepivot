#!/usr/bin/env bash
# Open the tunnel and drop into an SSH shell on the pod.
#
#   ./scripts/connect.sh <node-host-or-ip> [https-nodeport] [local-port]
#
# Example:
#   ./scripts/connect.sh 203.0.113.10 30443 2200
#
# Requires the wstunnel client locally:
#   https://github.com/erebe/wstunnel/releases
set -euo pipefail

HOST="${1:?usage: connect.sh <node-host-or-ip> [https-nodeport] [local-port]}"
HTTPS_PORT="${2:-30443}"
LOCAL_PORT="${3:-2200}"
POD_SSH_PORT="2222"
SSH_USER="${SSH_USER:-pentester}"

echo "[*] Opening tunnel: local :${LOCAL_PORT} -> wss://${HOST}:${HTTPS_PORT} -> pod sshd :${POD_SSH_PORT}"
wstunnel client -L "tcp://${LOCAL_PORT}:127.0.0.1:${POD_SSH_PORT}" "wss://${HOST}:${HTTPS_PORT}" &
WS_PID=$!
trap 'kill "${WS_PID}" 2>/dev/null || true' EXIT

sleep 1
echo "[*] SSH -> ${SSH_USER}@127.0.0.1:${LOCAL_PORT}"
# Host keys are regenerated each pod start, so we don't pin them here.
ssh -p "${LOCAL_PORT}" \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    "${SSH_USER}@127.0.0.1"
