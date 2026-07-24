#!/usr/bin/env bash
set -euo pipefail

USERNAME=dev
HOME_DIR="/home/${USERNAME}"
SSH_DIR="${HOME_DIR}/.ssh"
WORKSPACE="${HOME_DIR}/workspace"

# Install the pubkey bind-mounted from the host. Re-read on every start so
# rotating the key on the host only needs a container restart.
mkdir -p "${SSH_DIR}"
if [ -f /tmp/host_key.pub ]; then
    cat /tmp/host_key.pub > "${SSH_DIR}/authorized_keys"
else
    echo "WARNING: no pubkey at /tmp/host_key.pub — sshd will reject every login" >&2
    touch "${SSH_DIR}/authorized_keys"
fi

# sshd hands these to non-interactive sessions; the shell files below cover
# interactive ones. Sourced from the container environment, so compose stays the
# single source of truth for the values.
# PATH deliberately not set here: pam_env applies /etc/environment afterwards and
# would override it. Cargo's PATH entry lives in /etc/environment instead.
# Truncate both files first — the entrypoint re-runs on every restart.
SECRETS_FILE="${HOME_DIR}/.config/devbox-env.sh"
mkdir -p "${HOME_DIR}/.config"
: > "${SSH_DIR}/environment"
: > /etc/profile.d/devbox-env.sh
: > "${SECRETS_FILE}"

for var in $(compgen -v | grep -E '^(CARGO_|SCCACHE_|RUSTC_WRAPPER$)'); do
    echo "${var}=${!var}" >> "${SSH_DIR}/environment"
    echo "export ${var}=\"${!var}\"" >> /etc/profile.d/devbox-env.sh
done

# Secrets go only in files the dev user alone can read — /etc/profile.d is
# world-readable, so a token must never be written there.
for var in GH_TOKEN CLAUDE_CODE_OAUTH_TOKEN; do
    [ -n "${!var-}" ] || continue
    echo "${var}=${!var}" >> "${SSH_DIR}/environment"
    echo "export ${var}=\"${!var}\"" >> "${SECRETS_FILE}"
done

# Interactive shells source the secrets file; Ubuntu's .bashrc exits early when
# non-interactive, which is why the ssh environment file is needed as well.
if ! grep -qF 'devbox-env.sh' "${HOME_DIR}/.bashrc" 2>/dev/null; then
    echo '[ -f ~/.config/devbox-env.sh ] && . ~/.config/devbox-env.sh' >> "${HOME_DIR}/.bashrc"
fi

chmod 700 "${SSH_DIR}"
chmod 600 "${SSH_DIR}/authorized_keys" "${SSH_DIR}/environment" "${SECRETS_FILE}"
chown -R "${USERNAME}:${USERNAME}" "${SSH_DIR}" "${HOME_DIR}/.config" "${HOME_DIR}/.bashrc"

# Named volumes mount as root-owned on first use.
TARGET_DIR="${CARGO_TARGET_DIR:-${HOME_DIR}/.cache/cargo-target}"
SCCACHE_CACHE_DIR="${SCCACHE_DIR:-${HOME_DIR}/.cache/sccache}"
mkdir -p "${WORKSPACE}" "${TARGET_DIR}" "${SCCACHE_CACHE_DIR}" \
         "${HOME_DIR}/.claude" "${HOME_DIR}/.vscode-server"
chown "${USERNAME}:${USERNAME}" \
    "${WORKSPACE}" "${TARGET_DIR}" "${SCCACHE_CACHE_DIR}" \
    "${HOME_DIR}/.claude" "${HOME_DIR}/.vscode-server"
[ -d "${HOME_DIR}/.cargo" ] && chown -R "${USERNAME}:${USERNAME}" "${HOME_DIR}/.cargo"

exec "$@"
