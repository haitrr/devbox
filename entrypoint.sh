#!/usr/bin/env bash
# Runs as root, because sshd needs root to bind its port and switch users.
# Only the two things that genuinely require root happen here; everything under
# /home/dev is done by user-setup.sh running as the dev user itself.
set -euo pipefail

USERNAME=dev

# Trust GitHub's host key system-wide. ~/.ssh is not on a volume, so a key
# accepted interactively is lost on rebuild and every git fetch then fails with
# "Host key verification failed". Written at startup rather than baked into the
# image, so rotating it is a `docker compose up -d`, not a rebuild.
if [ -n "${GITHUB_KNOWN_HOSTS:-}" ]; then
    printf '%s\n' "${GITHUB_KNOWN_HOSTS}" > /etc/ssh/ssh_known_hosts
    chmod 644 /etc/ssh/ssh_known_hosts
else
    echo "NOTE: GITHUB_KNOWN_HOSTS unset — git over SSH will fail host key checks." >&2
fi

# Generate host keys once, into the volume. Keeping them out of the image means
# the container keeps a stable SSH identity across rebuilds, so clients that
# check known_hosts (Orca, VS Code) don't see a new machine every time.
for type in ed25519 rsa; do
    key="/etc/ssh/host-keys/ssh_host_${type}_key"
    [ -f "${key}" ] || ssh-keygen -q -t "${type}" -N '' -C "devbox" -f "${key}"
done
chmod 600 /etc/ssh/host-keys/ssh_host_*_key
chmod 644 /etc/ssh/host-keys/ssh_host_*_key.pub

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
