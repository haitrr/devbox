#!/usr/bin/env bash
# Runs as root, because sshd needs root to bind its port and switch users.
# Only the two things that genuinely require root happen here; everything under
# /home/dev is done by user-setup.sh running as the dev user itself.
set -euo pipefail

USERNAME=dev

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

# Non-secret config for interactive login shells. Root-owned and world-readable
# by design, which is exactly why secrets are written to the user's own file.
: > /etc/profile.d/devbox-env.sh
for var in $(compgen -v | grep -E '^(CARGO_|SCCACHE_|RUSTC_WRAPPER$)'); do
    echo "export ${var}=\"${!var}\"" >> /etc/profile.d/devbox-env.sh
done

# Drop to the user for everything under its home directory. runuser preserves
# the environment, so the tokens and CARGO_* values reach the script.
runuser -u "${USERNAME}" -- /usr/local/bin/user-setup.sh

exec "$@"
