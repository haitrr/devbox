#!/usr/bin/env bash
set -euo pipefail

USERNAME=dev
HOME_DIR="/home/${USERNAME}"
SSH_DIR="${HOME_DIR}/.ssh"
SECRETS_FILE="${HOME_DIR}/.config/devbox-env.sh"

# `install` creates with the right owner and mode in one step. Writing as root
# and chowning afterwards would work too, but this keeps ownership correct by
# construction — root appending to an existing file leaves its owner alone.
mkfile() { install -o "${USERNAME}" -g "${USERNAME}" -m "$1" /dev/null "$2"; }

install -d -o "${USERNAME}" -g "${USERNAME}" -m 700 "${SSH_DIR}"
install -d -o "${USERNAME}" -g "${USERNAME}" -m 755 "${HOME_DIR}/.config"

# Install the pubkey bind-mounted from the host. Re-read on every start so
# rotating the key on the host only needs a container restart.
mkfile 600 "${SSH_DIR}/authorized_keys"
if [ -f /tmp/host_key.pub ]; then
    cat /tmp/host_key.pub > "${SSH_DIR}/authorized_keys"
else
    echo "WARNING: no pubkey at /tmp/host_key.pub — sshd will reject every login" >&2
fi

# sshd hands these to non-interactive sessions; the shell files below cover
# interactive ones. Compose stays the single source of truth for the values.
# PATH deliberately not set here: pam_env applies /etc/environment afterwards and
# would override it. Cargo's PATH entry lives in /etc/environment instead.
# Recreated on every start, since the entrypoint re-runs on restart.
mkfile 600 "${SSH_DIR}/environment"
mkfile 600 "${SECRETS_FILE}"
: > /etc/profile.d/devbox-env.sh   # root-owned and world-readable by design

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

# sudo needs a password (see the sudoers line in the Dockerfile). Set it from
# SUDO_PASSWORD if provided; otherwise leave the account locked so sudo simply
# refuses rather than silently granting root. Deliberately not exported into any
# session file — it is an authentication secret, not configuration.
if [ -n "${SUDO_PASSWORD:-}" ]; then
    echo "${USERNAME}:${SUDO_PASSWORD}" | chpasswd
else
    passwd --lock "${USERNAME}" >/dev/null
    echo "NOTE: SUDO_PASSWORD unset — sudo is disabled for ${USERNAME}." >&2
    echo "      Use 'docker exec -u root devbox ...' for root work." >&2
fi

# Interactive shells source the secrets file; Ubuntu's .bashrc exits early when
# non-interactive, which is why the ssh environment file is needed as well.
# Appending leaves .bashrc's existing ownership intact.
if ! grep -qF 'devbox-env.sh' "${HOME_DIR}/.bashrc" 2>/dev/null; then
    echo '[ -f ~/.config/devbox-env.sh ] && . ~/.config/devbox-env.sh' >> "${HOME_DIR}/.bashrc"
fi

# The Dockerfile pre-creates every default mountpoint owned by the user, so
# volumes come up writable with no work here. These two are configurable via
# CARGO_TARGET_DIR / SCCACHE_DIR, so a non-default value still needs setting up.
for d in "${CARGO_TARGET_DIR:-${HOME_DIR}/.cache/cargo-target}" \
         "${SCCACHE_DIR:-${HOME_DIR}/.cache/sccache}"; do
    [ -d "${d}" ] || install -d -o "${USERNAME}" -g "${USERNAME}" "${d}"
done

# ~/.claude.json holds Claude Code's onboarding state and its per-project session
# index. It sits outside the .claude volume, so a rebuild both reset the login/
# onboarding picker and orphaned every past session. Keep the real file inside
# the volume and symlink it into place.
CLAUDE_JSON="${HOME_DIR}/.claude.json"
CLAUDE_JSON_STORE="${HOME_DIR}/.claude/claude.json"

if [ ! -L "${CLAUDE_JSON}" ]; then
    # Preserve an existing real file on first migration rather than dropping it.
    if [ -f "${CLAUDE_JSON}" ] && [ ! -f "${CLAUDE_JSON_STORE}" ]; then
        mv "${CLAUDE_JSON}" "${CLAUDE_JSON_STORE}"
    fi
    rm -f "${CLAUDE_JSON}"
    [ -f "${CLAUDE_JSON_STORE}" ] || mkfile 600 "${CLAUDE_JSON_STORE}"
    # Created as the user so the symlink isn't left owned by root.
    runuser -u "${USERNAME}" -- ln -s "${CLAUDE_JSON_STORE}" "${CLAUDE_JSON}"
fi

runuser -u "${USERNAME}" -- node -e '
const fs = require("fs");
const p = process.argv[1];
let d = {};
try { d = JSON.parse(fs.readFileSync(p, "utf8")); } catch (e) { /* missing or corrupt */ }
if (d.hasCompletedOnboarding !== true) {
    d.hasCompletedOnboarding = true;
    fs.writeFileSync(p, JSON.stringify(d, null, 2));
    console.log("seeded hasCompletedOnboarding in " + p);
}
' "${CLAUDE_JSON_STORE}" || echo "WARNING: could not seed ${CLAUDE_JSON_STORE}" >&2

exec "$@"
