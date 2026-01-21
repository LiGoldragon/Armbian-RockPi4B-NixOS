#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./criome-bootstrap-user.sh <ip-or-host>

IP="${1:-}"
[[ -n "$IP" ]] || {
    echo "Missing IP/host"
    exit 2
}

LOCAL_USER="$(id -un)"

if [[ "$LOCAL_USER" == "root" ]]; then
    echo "Refusing to run as local root. Run as your normal user."
    exit 3
fi

KEYS_SRC="/etc/ssh/authorized_keys.d/${LOCAL_USER}"

if [[ ! -f "$KEYS_SRC" ]]; then
    echo "Missing local keys file: $KEYS_SRC"
    exit 4
fi

SSH_OPTS="-o StrictHostKeyChecking=accept-new"

ssh $SSH_OPTS "root@${IP}" "bash -s" -- "$LOCAL_USER" <<'REMOTE'
set -euo pipefail

USER_NAME="${1:?missing username}"

KEYS_SRC="/etc/ssh/authorized_keys.d/${USER_NAME}"
HOME_DIR="/home/${USER_NAME}"
AK_DST="${HOME_DIR}/.ssh/authorized_keys"

log() { printf '[%s] %s\n' "$(date -Is)" "$*"; }

if id "$USER_NAME" >/dev/null 2>&1; then
  log "User '$USER_NAME' already exists. Refusing to overwrite."
  exit 0
fi

log "Creating user: $USER_NAME"
useradd -m -s /bin/bash "$USER_NAME"

if getent group sudo >/dev/null; then
  usermod -aG sudo "$USER_NAME"
elif getent group wheel >/dev/null; then
  usermod -aG wheel "$USER_NAME"
fi

if [[ ! -f "$KEYS_SRC" ]]; then
  echo "Remote keys file missing: $KEYS_SRC" >&2
  exit 5
fi

install -d -m 700 "$HOME_DIR/.ssh"
install -m 600 /dev/null "$AK_DST"
cat "$KEYS_SRC" > "$AK_DST"

chown -R "$USER_NAME:$USER_NAME" "$HOME_DIR/.ssh"

log "User created and SSH keys installed."
REMOTE
