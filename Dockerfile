FROM ubuntu:24.04

ARG USERNAME=dev
ARG NODE_MAJOR=22
ARG SCCACHE_VERSION=v0.16.0

# Base toolchain + sshd. mold comes from the Ubuntu archive (24.04 ships mold 2.x).
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        curl \
        git \
        less \
        libssl-dev \
        mold \
        openssh-server \
        pkg-config \
        ripgrep \
        sudo \
        unzip \
        vim \
        wget \
    && rm -rf /var/lib/apt/lists/*

# Node LTS from NodeSource, plus the Next.js CLI for scaffolding.
RUN curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x | bash - \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends nodejs \
    && npm install -g next @anthropic-ai/claude-code \
    && rm -rf /var/lib/apt/lists/*

# sccache — static musl build from upstream releases (not in the Ubuntu archive).
# Lands in /usr/local/bin, which is already on the PATH in /etc/environment, so
# non-interactive SSH sessions resolve it too.
RUN arch="$(dpkg --print-architecture)" \
    && case "${arch}" in \
         arm64) target=aarch64-unknown-linux-musl ;; \
         amd64) target=x86_64-unknown-linux-musl ;; \
         *) echo "unsupported architecture: ${arch}" >&2; exit 1 ;; \
       esac \
    && curl -fsSL "https://github.com/mozilla/sccache/releases/download/${SCCACHE_VERSION}/sccache-${SCCACHE_VERSION}-${target}.tar.gz" \
       | tar -xz -C /tmp \
    && install -m 0755 "/tmp/sccache-${SCCACHE_VERSION}-${target}/sccache" /usr/local/bin/sccache \
    && rm -rf "/tmp/sccache-${SCCACHE_VERSION}-${target}" \
    && sccache --version

# GitHub CLI from GitHub's own apt repo (the Ubuntu archive version lags).
RUN mkdir -p -m 755 /etc/apt/keyrings \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
         -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
         > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# Unprivileged user. sudo requires a password, so a process running as this user
# cannot silently escalate to root. The entrypoint sets the password from
# SUDO_PASSWORD; with none set the account stays locked and sudo is unusable.
# SSH login is by key only either way (PasswordAuthentication no).
RUN useradd --create-home --shell /bin/bash ${USERNAME} \
    && echo "${USERNAME} ALL=(ALL) ALL" > /etc/sudoers.d/${USERNAME} \
    && chmod 0440 /etc/sudoers.d/${USERNAME} \
    && passwd --lock ${USERNAME}

# Create every volume mountpoint here, owned by the user. A named volume seeds
# itself from the image's content at that path *including ownership*; when the
# path is absent from the image, Docker instead creates it empty and root-owned,
# which the entrypoint would then have to chown on every start.
RUN mkdir -p \
        /home/${USERNAME}/workspace \
        /home/${USERNAME}/.claude \
        /home/${USERNAME}/.config \
        /home/${USERNAME}/.vscode-server \
        /home/${USERNAME}/.orca \
        /home/${USERNAME}/.orca-relay \
        /home/${USERNAME}/.orca-remote \
        /home/${USERNAME}/.cargo/registry \
        /home/${USERNAME}/.cache/cargo-target \
        /home/${USERNAME}/.cache/sccache \
    && chown -R ${USERNAME}:${USERNAME} /home/${USERNAME}

# Key-only SSH. PermitUserEnvironment lets the entrypoint hand the CARGO_* vars
# to non-interactive sessions (`ssh devbox cargo build`), which otherwise inherit
# nothing from the daemon.
# Host keys live on a volume, not in the image: image-baked keys are regenerated
# by every rebuild, so the container looks like a different machine each time and
# strict SSH clients (Orca, and anything using known_hosts) refuse to connect.
RUN mkdir -p /run/sshd /etc/ssh/host-keys \
    && printf '%s\n' \
        'PasswordAuthentication no' \
        'PubkeyAuthentication yes' \
        'PermitRootLogin no' \
        'PermitUserEnvironment yes' \
        'HostKey /etc/ssh/host-keys/ssh_host_ed25519_key' \
        'HostKey /etc/ssh/host-keys/ssh_host_rsa_key' \
        > /etc/ssh/sshd_config.d/devbox.conf

USER ${USERNAME}
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
    | sh -s -- -y --no-modify-path --profile minimal --component clippy --component rustfmt

USER root
# Interactive shells get cargo on PATH; the entrypoint appends the CARGO_* vars here.
RUN printf 'export PATH=/home/%s/.cargo/bin:$PATH\n' "${USERNAME}" > /etc/profile.d/devbox-path.sh

# Non-interactive SSH (`ssh devbox cargo build`) gets PATH from /etc/environment
# via pam_env, which runs after sshd reads ~/.ssh/environment and overrides it.
# Cargo has to be here or it is invisible to non-login shells.
RUN sed -i "s|^PATH=\"|PATH=\"/home/${USERNAME}/.cargo/bin:|" /etc/environment

COPY entrypoint.sh user-setup.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/user-setup.sh

EXPOSE 22
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["/usr/sbin/sshd", "-D", "-e"]
