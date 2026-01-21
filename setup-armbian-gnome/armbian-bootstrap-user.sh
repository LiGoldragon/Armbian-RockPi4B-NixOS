#!/usr/bin/env bash
set -euo pipefail

# criome-bootstrap-user.sh
# Usage:
#   ./criome-bootstrap-user.sh <ip-or-host> <username>
#
# Effect (remote host):
# - SSH in as root
# - Create <username> if missing (home + bash)
# - Add <username> to sudo
# - Copy keys from /etc/ssh/authorized_keys.d/<username> into:
#     /home/<username>/.ssh/authorized_keys
# - Fix ownership + perms

IP="${1:-}"
USER_NAME="${2:-}"

[[ -n "$IP" ]] || {
    echo "Missing IP/host"
    exit 2
}
[[ -n "$USER_NAME" ]] || {
    echo "Missing username"
    exit 2
}

# Optional: override by exporting SSH_OPTS
SSH_OPTS_DEFAULT="-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$HOME/.ssh/known_hosts"
SSH_OPTS="${SSH_OPTS:-$SSH_OPTS_DEFAULT}"

ssh $SSH_OPTS "root@${IP}" "bash -s" -- "$USER_NAME" <<'REMOTE'
set -euo pipefail

USER_NAME="${1:?missing username}"

KEYS_SRC="/etc/ssh/authorized_keys.d/${USER_NAME}"
HOME_DIR="/home/${USER_NAME}"
AK_DST="${HOME_DIR}/.ssh/authorized_keys"

log() { printf '[%s] %s\n' "$(date -Is)" "$*"; }

log "Ensuring user exists: ${USER_NAME}"
if ! id "${USER_NAME}" >/dev/null 2>&1; then
  useradd -m -s /bin/bash "${USER_NAME}"
else
  log "User already exists."
fi

log "Ensuring sudo group membership."
if getent group sudo >/dev/null 2>&1; then
  usermod -aG sudo "${USER_NAME}"
elif getent group wheel >/dev/null 2>&1; then
  usermod -aG wheel "${USER_NAME}"
else
  log "No sudo/wheel group found; skipping group add."
fi

log "Creating ~/.ssh with correct permissions."
install -d -m 700 "${HOME_DIR}/.ssh"
chown "${USER_NAME}:${USER_NAME}" "${HOME_DIR}/.ssh"

log "Copying authorized keys from: ${KEYS_SRC}"
if [[ ! -f "${KEYS_SRC}" ]]; then
  echo "ERROR: Missing keys file: ${KEYS_SRC}" >&2
  exit 3
fi

# Copy keys (overwrite destination to match source exactly).
install -m 600 /dev/null "${AK_DST}"
cat "${KEYS_SRC}" > "${AK_DST}"
chown "${USER_NAME}:${USER_NAME}" "${AK_DST}"
chmod 600 "${AK_DST}"

log "Done. Test:"
log "  ssh ${USER_NAME}@$(hostname -I | awk '{print $1}')"
REMOTE
