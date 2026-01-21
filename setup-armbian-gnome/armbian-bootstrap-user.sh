#!/usr/bin/env bash
set -euo pipefail

# armbian-bootstrap-user.sh
# Usage:
#   ./armbian-bootstrap-user.sh <ip-or-host> [--align-criomos] [--force]
#
# Modes:
# - default: create user if missing; refuse overwrite
# - --force: user may already exist; ensure keys are present (append missing only)
# - --align-criomos: also maintain /etc/ssh/authorized_keys.d/$USER and sshd_config

IP="${1:-}"
MODE1="${2:-}"
MODE2="${3:-}"

[[ -n "$IP" ]] || {
    echo "Missing IP/host"
    exit 2
}

LOCAL_USER="$(id -un)"
[[ "$LOCAL_USER" != "root" ]] || {
    echo "Refusing local root."
    exit 3
}

ALIGN=false
FORCE=false
for m in "${MODE1:-}" "${MODE2:-}"; do
    [[ "$m" == "--align-criomos" ]] && ALIGN=true
    [[ "$m" == "--force" ]] && FORCE=true
done

pick_keys_source() {
    local u="$1"
    if [[ -f "/etc/ssh/authorized_keys.d/$u" ]]; then
        echo "/etc/ssh/authorized_keys.d/$u"
        return 0
    fi
    if [[ -f "$HOME/.ssh/authorized_keys" ]]; then
        echo "$HOME/.ssh/authorized_keys"
        return 0
    fi
    if [[ -f "$HOME/.ssh/id_ed25519.pub" ]]; then
        echo "$HOME/.ssh/id_ed25519.pub"
        return 0
    fi
    return 1
}

KEYS_SRC="$(pick_keys_source "$LOCAL_USER")" || {
    echo "No local keys found. Expected one of:"
    echo "  /etc/ssh/authorized_keys.d/$LOCAL_USER"
    echo "  $HOME/.ssh/authorized_keys"
    echo "  $HOME/.ssh/id_ed25519.pub"
    exit 4
}

KEYS_CONTENT="$(cat "$KEYS_SRC")"

SSH_OPTS="-o StrictHostKeyChecking=accept-new"

ssh $SSH_OPTS "root@${IP}" "bash -s" -- "$LOCAL_USER" "$ALIGN" "$FORCE" <<REMOTE
set -euo pipefail

USER_NAME="\$1"
ALIGN="\$2"
FORCE="\$3"

HOME_DIR="/home/\${USER_NAME}"
AK_DST="\${HOME_DIR}/.ssh/authorized_keys"

log() { printf '[%s] %s\n' "\$(date -Is)" "\$*"; }

tmp="\$(mktemp)"
cat > "\$tmp" <<'KEYS'
${KEYS_CONTENT}
KEYS
chmod 600 "\$tmp"

ensure_user() {
  if id "\$USER_NAME" >/dev/null 2>&1; then
    if [[ "\$FORCE" == "true" ]]; then
      log "User '\$USER_NAME' exists; continuing due to --force."
      return 0
    fi
    log "User '\$USER_NAME' already exists. Refusing to overwrite."
    exit 0
  fi

  log "Creating user: \$USER_NAME"
  useradd -m -s /bin/bash "\$USER_NAME"

  if getent group sudo >/dev/null 2>&1; then
    usermod -aG sudo "\$USER_NAME"
  elif getent group wheel >/dev/null 2>&1; then
    usermod -aG wheel "\$USER_NAME"
  fi
}

append_missing_keys() {
  local dst="\$1"

  install -d -m 700 "\$(dirname "\$dst")"
  touch "\$dst"
  chmod 600 "\$dst"
  chown -R "\$USER_NAME:\$USER_NAME" "\$HOME_DIR/.ssh"

  local added=0
  while IFS= read -r keyline; do
    [[ -z "\$keyline" ]] && continue
    # Append only if exact line not present.
    if ! grep -Fxq "\$keyline" "\$dst"; then
      printf '%s\n' "\$keyline" >> "\$dst"
      added=\$((added+1))
    fi
  done < "\$tmp"

  chown "\$USER_NAME:\$USER_NAME" "\$dst"
  chmod 600 "\$dst"
  log "Key sync complete for \$dst (added \${added})."
}

align_criomos() {
  install -d -m 755 /etc/ssh/authorized_keys.d
  local sysdst="/etc/ssh/authorized_keys.d/\$USER_NAME"
  touch "\$sysdst"
  chmod 644 "\$sysdst"
  append_missing_keys "\$sysdst"

  if grep -qE '^[[:space:]]*AuthorizedKeysFile[[:space:]]' /etc/ssh/sshd_config; then
    sed -i -E 's|^[[:space:]]*AuthorizedKeysFile[[:space:]]+.*$|AuthorizedKeysFile .ssh/authorized_keys /etc/ssh/authorized_keys.d/%u|' /etc/ssh/sshd_config
  else
    printf '\nAuthorizedKeysFile .ssh/authorized_keys /etc/ssh/authorized_keys.d/%%u\n' >> /etc/ssh/sshd_config
  fi

  systemctl restart ssh || systemctl restart sshd || true
}

ensure_user

# Ensure the home directory exists even if user existed but was created oddly.
if [[ ! -d "\$HOME_DIR" ]]; then
  log "Home directory missing; creating: \$HOME_DIR"
  mkdir -p "\$HOME_DIR"
  chown "\$USER_NAME:\$USER_NAME" "\$HOME_DIR"
fi

# Always ensure per-user authorized_keys is synced.
append_missing_keys "\$AK_DST"

if [[ "\$ALIGN" == "true" ]]; then
  log "Applying CriomOS alignment."
  align_criomos
fi

rm -f "\$tmp"
log "Done."
REMOTE
