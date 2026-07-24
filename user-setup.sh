#!/usr/bin/env bash
# Runs as the dev user (see entrypoint.sh). Everything here writes under $HOME,
# so nothing needs root and nothing needs its ownership corrected afterwards.
set -euo pipefail

SSH_DIR="${HOME}/.ssh"
SECRETS_FILE="${HOME}/.config/devbox-env.sh"

mkdir -p "${SSH_DIR}" "${HOME}/.config"
chmod 700 "${SSH_DIR}"

# Install the pubkey bind-mounted from the host. Re-read on every start so
# rotating the key on the host only needs a container restart.
if [ -f /tmp/host_key.pub ]; then
    cat /tmp/host_key.pub > "${SSH_DIR}/authorized_keys"
else
    echo "WARNING: no pubkey at /tmp/host_key.pub — sshd will reject every login" >&2
    : > "${SSH_DIR}/authorized_keys"
fi
chmod 600 "${SSH_DIR}/authorized_keys"

# sshd hands these to non-interactive sessions; .bashrc covers interactive ones.
# PATH deliberately not set here: pam_env applies /etc/environment afterwards and
# would override it. Cargo's PATH entry lives in /etc/environment instead.
# Recreated on every start, since this runs again on restart.
: > "${SSH_DIR}/environment"
: > "${SECRETS_FILE}"
chmod 600 "${SSH_DIR}/environment" "${SECRETS_FILE}"

for var in $(compgen -v | grep -E '^(CARGO_|SCCACHE_|RUSTC_WRAPPER$)'); do
    echo "${var}=${!var}" >> "${SSH_DIR}/environment"
done

# Secrets go only in files the dev user alone can read — the root-written
# /etc/profile.d/devbox-env.sh is world-readable, so no token may go there.
for var in GH_TOKEN CLAUDE_CODE_OAUTH_TOKEN; do
    [ -n "${!var-}" ] || continue
    echo "${var}=${!var}" >> "${SSH_DIR}/environment"
    echo "export ${var}=\"${!var}\"" >> "${SECRETS_FILE}"
done

# Ubuntu's .bashrc exits early when non-interactive, which is why the ssh
# environment file above is needed as well.
if ! grep -qF 'devbox-env.sh' "${HOME}/.bashrc" 2>/dev/null; then
    echo '[ -f ~/.config/devbox-env.sh ] && . ~/.config/devbox-env.sh' >> "${HOME}/.bashrc"
fi

# The Dockerfile pre-creates every default mountpoint, so volumes come up
# writable. These two are configurable, so a non-default value still needs it.
mkdir -p "${CARGO_TARGET_DIR:-${HOME}/.cache/cargo-target}" \
         "${SCCACHE_DIR:-${HOME}/.cache/sccache}"

# Authenticate git from GH_TOKEN rather than a forwarded SSH agent. Tools that
# connect without agent forwarding — Orca, unattended agents, cron — otherwise
# fail every fetch with "Permission denied (publickey)". SSH remotes are
# rewritten to HTTPS so existing clones keep working untouched.
if [ -n "${GH_TOKEN:-}" ] && command -v gh >/dev/null; then
    git config --global credential."https://github.com".helper '!gh auth git-credential'
    git config --global --unset-all url."https://github.com/".insteadOf 2>/dev/null || true
    git config --global --add url."https://github.com/".insteadOf 'git@github.com:'
    git config --global --add url."https://github.com/".insteadOf 'ssh://git@github.com/'
fi

# ~/.claude.json holds Claude Code's onboarding state and its per-project session
# index. It sits outside the .claude volume, so a rebuild both reset the login/
# onboarding picker and orphaned every past session. Keep the real file inside
# the volume and symlink it into place.
CLAUDE_JSON="${HOME}/.claude.json"
CLAUDE_JSON_STORE="${HOME}/.claude/claude.json"

if [ ! -L "${CLAUDE_JSON}" ]; then
    # Preserve an existing real file on first migration rather than dropping it.
    if [ -f "${CLAUDE_JSON}" ] && [ ! -f "${CLAUDE_JSON_STORE}" ]; then
        mv "${CLAUDE_JSON}" "${CLAUDE_JSON_STORE}"
    fi
    rm -f "${CLAUDE_JSON}"
    [ -f "${CLAUDE_JSON_STORE}" ] || echo '{}' > "${CLAUDE_JSON_STORE}"
    ln -s "${CLAUDE_JSON_STORE}" "${CLAUDE_JSON}"
fi
chmod 600 "${CLAUDE_JSON_STORE}"

node -e '
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
