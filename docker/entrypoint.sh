#!/usr/bin/env bash
set -euo pipefail
[ "${DEBUG:-false}" = "true" ] && set -x

# --- Paths -------------------------------------------------------------------
WRITABLE="/writable"
APACHE_WRITABLE="$WRITABLE/etc/apache"
SSH_WRITABLE="$WRITABLE/etc/ssh"
RUN_DIR="$WRITABLE/var/run"
PENTEST_DIR="/pentest"

# --- Tunables (overridable via env / manifest) -------------------------------
WS_TUNNEL_PORT="${WS_TUNNEL_PORT:-30000}"   # internal ws backend port
SSH_PORT="${SSH_PORT:-2222}"                # sshd listen port
DOMAIN_NAME="${DOMAIN_NAME:-localhost}"     # CN/SAN of the self-signed cert

# --- Self-signed TLS cert for Apache (only if missing) -----------------------
if [ ! -s "$APACHE_WRITABLE/tls.crt" ] || [ ! -s "$APACHE_WRITABLE/tls.key" ]; then
  echo "[*] Generating self-signed certificate for CN=${DOMAIN_NAME}"
  openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 3650 \
    -keyout "$APACHE_WRITABLE/tls.key" -out "$APACHE_WRITABLE/tls.crt" \
    -subj "/CN=${DOMAIN_NAME}" \
    -addext "subjectAltName = DNS:${DOMAIN_NAME}" \
    -addext "basicConstraints = CA:FALSE" \
    -addext "keyUsage = digitalSignature,keyEncipherment" \
    -addext "extendedKeyUsage = serverAuth"
  chmod 600 "$APACHE_WRITABLE/tls.key"
fi

# --- SSH host keys (generate once if absent; keys are ephemeral per pod) ------
[ -s "$SSH_WRITABLE/ssh_host_ed25519_key" ] || ssh-keygen -t ed25519   -f "$SSH_WRITABLE/ssh_host_ed25519_key" -N '' -q
[ -s "$SSH_WRITABLE/ssh_host_ecdsa_key"   ] || ssh-keygen -t ecdsa     -f "$SSH_WRITABLE/ssh_host_ecdsa_key"   -N '' -q
[ -s "$SSH_WRITABLE/ssh_host_rsa_key"     ] || ssh-keygen -t rsa -b 4096 -f "$SSH_WRITABLE/ssh_host_rsa_key"   -N '' -q
chmod 600 "$SSH_WRITABLE"/ssh_host_*_key
chmod 644 "$SSH_WRITABLE"/ssh_host_*.pub

# --- Warn if no authorized_keys was mounted ----------------------------------
# The key is mounted (via subPath) at this path from the Kubernetes Secret.
AUTH_KEYS="/etc/kubepivot/ssh/authorized_keys"
if [ ! -s "$AUTH_KEYS" ]; then
  echo "[!] WARNING: $AUTH_KEYS is empty or missing — no one will be able to log in."
  echo "[!] Provide your public key via the Secret (see k8s/)."
fi

# --- Service launcher --------------------------------------------------------
start_service() {
  local name="${1##*/}"
  echo "[*] Starting $name" >&2
  "$@" >&2 &
  local pid="$!"
  mkdir -p "$RUN_DIR/$name"
  echo "$pid" > "$RUN_DIR/$name/$name.pid"
}

# wstunnel backend: ws://127.0.0.1:WS_TUNNEL_PORT -> restricted to sshd only
echo "[*] Starting wstunnel ws://127.0.0.1:${WS_TUNNEL_PORT} -> 127.0.0.1:${SSH_PORT}"
"${PENTEST_DIR}/ws_tunnel.sh" "127.0.0.1:${SSH_PORT}" "${WS_TUNNEL_PORT}" &

# Apache HTTPS reverse-proxy on :8443
echo "[*] Starting Apache HTTPS on :8443"
APACHE_ENVVARS="$APACHE_WRITABLE/envvars" start_service apachectl start

# sshd on :SSH_PORT
echo "[*] Starting sshd on :${SSH_PORT}"
start_service /usr/sbin/sshd -D -e -f "$SSH_WRITABLE/sshd_config"

# Keep the container alive (services run in the background above).
exec tail -f /dev/null
