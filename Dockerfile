FROM ubuntu:24.04

ARG USERNAME=dev
ARG NODE_MAJOR=22
ARG SCCACHE_VERSION=v0.16.0
# mold is installed from upstream releases below, not the Ubuntu archive: 24.04
# ships mold 2.30 (Mar 2024), and upstream is far ahead. Bump this to upgrade.
ARG MOLD_VERSION=v2.41.0
# Tools with no usable Ubuntu package (trivy, duckdb, mikefarah's yq) or whose
# archive version lags badly (just 1.21 vs upstream 1.57). Bump to upgrade.
ARG JUST_VERSION=1.57.0
ARG YQ_VERSION=v4.53.3
ARG TRIVY_VERSION=v0.72.0
ARG DUCKDB_VERSION=v1.5.5
# Cargo subcommands, installed as prebuilt binaries via cargo-binstall.
ARG BINSTALL_VERSION=v1.21.1
ARG NEXTEST_VERSION=0.9.140
ARG CARGO_DENY_VERSION=0.20.2
ARG CARGO_EXPAND_VERSION=1.0.124
ARG CARGO_MACHETE_VERSION=0.9.2
# uv (Astral's Python package manager, a static binary) and the code-review-graph
# CLI it installs. Bump either independently.
ARG UV_VERSION=0.12.1
ARG CRG_VERSION=2.3.7
# Playwright. The browser builds are keyed to the release that downloaded them,
# so bumping this re-downloads them on the next build. Chromium only by default:
# adding firefox and webkit roughly triples the layer.
ARG PLAYWRIGHT_VERSION=1.62.1
ARG PLAYWRIGHT_BROWSERS="chromium"

# Base toolchain + sshd.
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        curl \
        git \
        less \
        libatomic1 \
        libssl-dev \
        openssh-server \
        pkg-config \
        ripgrep \
        sudo \
        unzip \
        vim \
        wget \
    && rm -rf /var/lib/apt/lists/*

# Everyday CLI tooling that the Ubuntu archive carries at a usable version.
# `time` is the standalone /usr/bin/time (bash's builtin has no -v / -f).
# fd-find and bat install under alternate names (fdfind, batcat) to avoid
# clashing with unrelated packages, so both get a symlink under their real name;
# /usr/local/bin is already on the PATH for interactive and SSH sessions alike.
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        bat \
        fd-find \
        git-delta \
        hyperfine \
        jq \
        lsof \
        netcat-openbsd \
        shellcheck \
        shfmt \
        sqlite3 \
        time \
        tree \
        zstd \
    && rm -rf /var/lib/apt/lists/* \
    && ln -s /usr/bin/fdfind /usr/local/bin/fd \
    && ln -s /usr/bin/batcat /usr/local/bin/bat

# Node LTS from NodeSource, plus the Next.js CLI for scaffolding. Corepack ships
# with Node and manages pnpm/yarn per-project via the packageManager field.
RUN curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x | bash - \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends nodejs \
    && corepack enable \
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

# mold — upstream prebuilt release (Ubuntu 24.04's archive lags years behind).
# The tarball is a /usr/local-style prefix (bin/mold, bin/ld.mold, lib/mold/
# mold-wrapper.so), so --strip-components=1 into /usr/local installs a complete,
# working linker; both `mold` and `ld.mold` land on PATH for -fuse-ld=mold.
RUN arch="$(dpkg --print-architecture)" \
    && case "${arch}" in \
         arm64) target=aarch64-linux ;; \
         amd64) target=x86_64-linux ;; \
         *) echo "unsupported architecture: ${arch}" >&2; exit 1 ;; \
       esac \
    && ver="${MOLD_VERSION#v}" \
    && curl -fsSL "https://github.com/rui314/mold/releases/download/${MOLD_VERSION}/mold-${ver}-${target}.tar.gz" \
       | tar -xz --strip-components=1 -C /usr/local \
    && mold --version

# just / yq / trivy / duckdb — upstream prebuilt releases into /usr/local/bin.
# Each publishes a different asset naming scheme, hence the per-tool triple.
# Note yq here is mikefarah's Go implementation (`yq '.a.b'`, `yq eval`), not the
# jq-wrapper Python package the Ubuntu archive ships under the same name.
RUN arch="$(dpkg --print-architecture)" \
    && case "${arch}" in \
         arm64) rust_target=aarch64-unknown-linux-musl; go_arch=arm64; trivy_arch=ARM64; duck_arch=arm64 ;; \
         amd64) rust_target=x86_64-unknown-linux-musl; go_arch=amd64; trivy_arch=64bit; duck_arch=amd64 ;; \
         *) echo "unsupported architecture: ${arch}" >&2; exit 1 ;; \
       esac \
    && curl -fsSL "https://github.com/casey/just/releases/download/${JUST_VERSION}/just-${JUST_VERSION}-${rust_target}.tar.gz" \
       | tar -xz -C /usr/local/bin just \
    && curl -fsSL "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${go_arch}" \
         -o /usr/local/bin/yq \
    && chmod 0755 /usr/local/bin/yq \
    && curl -fsSL "https://github.com/aquasecurity/trivy/releases/download/${TRIVY_VERSION}/trivy_${TRIVY_VERSION#v}_Linux-${trivy_arch}.tar.gz" \
       | tar -xz -C /usr/local/bin trivy \
    && curl -fsSL "https://github.com/duckdb/duckdb/releases/download/${DUCKDB_VERSION}/duckdb_cli-linux-${duck_arch}.gz" \
       | gunzip > /usr/local/bin/duckdb \
    && chmod 0755 /usr/local/bin/duckdb \
    && just --version && yq --version && trivy --version && duckdb --version

# Cargo subcommands as prebuilt binaries. cargo-binstall resolves each crate's
# own release assets — and falls back to the cargo-quickinstall builds for
# cargo-expand, which publishes no binaries of its own — so nothing here is
# compiled from source. `compile` is disabled explicitly: root has no rustc on
# PATH (rustup is installed under the dev user below), so a silent fallback to a
# source build would fail late and confusingly rather than at the download.
# Note: `cargo expand` itself needs a nightly rustc (-Zunpretty=expanded). The
# rustup install below is stable-only to keep the image small; add nightly with
# `rustup toolchain install nightly --profile minimal` (~500MB) if you use it.
RUN arch="$(dpkg --print-architecture)" \
    && case "${arch}" in \
         arm64) target=aarch64-unknown-linux-gnu ;; \
         amd64) target=x86_64-unknown-linux-gnu ;; \
         *) echo "unsupported architecture: ${arch}" >&2; exit 1 ;; \
       esac \
    && curl -fsSL "https://github.com/cargo-bins/cargo-binstall/releases/download/${BINSTALL_VERSION}/cargo-binstall-${target}.tgz" \
       | tar -xz -C /usr/local/bin cargo-binstall \
    && cargo-binstall --no-confirm --no-track --disable-strategies compile \
         --install-path /usr/local/bin \
         "cargo-nextest@${NEXTEST_VERSION}" \
         "cargo-deny@${CARGO_DENY_VERSION}" \
         "cargo-expand@${CARGO_EXPAND_VERSION}" \
         "cargo-machete@${CARGO_MACHETE_VERSION}" \
    && cargo-nextest --version && cargo-deny --version \
    && cargo-expand --version && cargo-machete --version

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

# code-review-graph — a Tree-sitter/MCP tool that maps a repo's structure so AI
# assistants read only the blast radius of a change instead of the whole corpus.
# Installed off its own toolchain: uv (Astral's static binary, matching this file's
# prebuilt-into-/usr/local/bin pattern) lands alongside uvx, then `uv tool install`
# builds a self-contained venv under /opt/uv on a uv-managed CPython — the ubuntu
# base carries no python — and symlinks the `code-review-graph`/`crg-daemon`
# launchers onto PATH. The UV_* vars are scoped to this RUN so they don't leak into
# the dev user's own `uv`/`uvx` at runtime; a final chmod makes the venv and the
# managed interpreter world-readable so the unprivileged user runs them too. uvx is
# also left on PATH because the project's generated MCP config invokes it.
RUN arch="$(dpkg --print-architecture)" \
    && case "${arch}" in \
         arm64) target=aarch64-unknown-linux-gnu ;; \
         amd64) target=x86_64-unknown-linux-gnu ;; \
         *) echo "unsupported architecture: ${arch}" >&2; exit 1 ;; \
       esac \
    && curl -fsSL "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-${target}.tar.gz" \
       | tar -xz --strip-components=1 -C /usr/local/bin \
    && uv --version && uvx --version \
    && UV_TOOL_DIR=/opt/uv/tools \
       UV_TOOL_BIN_DIR=/usr/local/bin \
       UV_PYTHON_INSTALL_DIR=/opt/uv/python \
       UV_PYTHON_PREFERENCE=only-managed \
       uv tool install --python 3.12 "code-review-graph@${CRG_VERSION}" \
    && chmod -R a+rX /opt/uv \
    && code-review-graph --version

# Python + pip. The base image ships no interpreter at all — the only python in
# here is the one uv hides under /opt/uv for code-review-graph's venv, which is an
# implementation detail of that tool, not a runtime — so shebangs, `python3` and
# `pip install` all miss. Taken from the Ubuntu archive rather than given the
# upstream-binary treatment the rest of this file gives lagging tools: 24.04 is on
# 3.12 and lands at /usr/bin/python3, which is where everything expects it.
# python3-dev plus the build-essential above lets C-extension wheels compile from
# an sdist when no wheel matches; python3-venv covers throwaway envs (as does uv).
# The symlinks provide the unsuffixed `python`/`pip` names out of /usr/local/bin,
# already on PATH for interactive and non-interactive SSH alike, in preference to
# python-is-python3 — that package owns /usr/bin/python and fights anything else
# that later wants the name.
#
# pip.conf lifts Ubuntu's PEP 668 externally-managed guard, which otherwise makes
# a bare `pip install requests` fail with a wall of text. In a disposable container
# a global install is the expected ergonomic, and flipping the documented flag is
# explicit and reversible where deleting the EXTERNALLY-MANAGED marker is neither.
# It matters for the dev user too: unprivileged installs fall back to a --user
# install, which the same guard blocks, and those land in ~/.local/bin — already
# first on PATH for the cargo shim, so pip-installed console scripts just work.
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        python3 \
        python3-dev \
        python3-pip \
        python3-venv \
    && rm -rf /var/lib/apt/lists/* \
    && ln -sf /usr/bin/python3 /usr/local/bin/python \
    && ln -sf /usr/bin/pip3 /usr/local/bin/pip \
    && printf '%s\n' '[global]' 'break-system-packages = true' > /etc/pip.conf \
    && python --version && pip --version

# Unprivileged user. sudo requires a password, so a process running as this user
# cannot silently escalate to root. The entrypoint sets the password from
# SUDO_PASSWORD; with none set the account stays locked and sudo is unusable.
# SSH login is by key only either way (PasswordAuthentication no).
RUN useradd --create-home --shell /bin/bash ${USERNAME} \
    && echo "${USERNAME} ALL=(ALL) ALL" > /etc/sudoers.d/${USERNAME} \
    && chmod 0440 /etc/sudoers.d/${USERNAME} \
    && passwd --lock ${USERNAME}

# Playwright: the runner and CLI globally, plus the browser builds and the system
# libraries they need, so `playwright test` in a fresh clone runs instead of
# stopping to download half a gigabyte first.
#
# Browsers go to /opt/playwright rather than the default ~/.cache/ms-playwright:
# the download runs as root here, and a per-user cache written by root is exactly
# what the dev user then can't use. The directory is handed to that user
# afterwards so an unprivileged `playwright install` still works — a project
# pinned to a different playwright version wants a different browser revision and
# will fetch it, since revisions live in sibling directories rather than
# overwriting these. PLAYWRIGHT_BROWSERS_PATH has to be set twice to be seen
# everywhere: as an ENV for `docker exec`, and in /etc/environment for SSH
# sessions, which inherit nothing from the daemon (the same reason PATH is
# written there below).
#
# `--with-deps` apt-installs Chromium's runtime libraries — libgtk-3-0t64,
# libnss3, libgbm1, libasound2t64, fonts. That is close to the set 475d751
# removed, arrived at from the other end: there they existed so a desktop .deb
# would configure, here headless Chromium cannot start without them. Nothing
# comes back with them, in particular not `seccomp:unconfined` — Playwright
# launches Chromium with chromiumSandbox off, so it never asks for
# unshare(CLONE_NEWUSER) and Docker's default profile stays intact.
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/playwright
RUN npm install -g "@playwright/test@${PLAYWRIGHT_VERSION}" \
    && playwright install --with-deps ${PLAYWRIGHT_BROWSERS} \
    && rm -rf /var/lib/apt/lists/* \
    && chown -R ${USERNAME}:${USERNAME} /opt/playwright \
    && echo 'PLAYWRIGHT_BROWSERS_PATH=/opt/playwright' >> /etc/environment \
    && playwright --version

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
# ClientAlive* keeps long-lived sessions alive and detects dead ones promptly.
# Connections arrive via the host's port forward on 2223, and every NAT hop in
# that chain drops idle mappings after minutes; host sleep or Wi-Fi roaming kills
# them outright. sshd defaults to ClientAliveInterval 0 (no probes) and leaves
# dead-peer detection to TCPKeepAlive, whose first probe waits out the kernel's
# tcp_keepalive_time — 7200s. So a session could sit wedged for two hours before
# either end noticed. Probing every 15s holds the mapping open and gives up after
# 8 misses (~2 min). Clients want the mirror image: ServerAliveInterval 15.
RUN mkdir -p /run/sshd /etc/ssh/host-keys \
    && printf '%s\n' \
        'PasswordAuthentication no' \
        'PubkeyAuthentication yes' \
        'PermitRootLogin no' \
        'PermitUserEnvironment yes' \
        'ClientAliveInterval 15' \
        'ClientAliveCountMax 8' \
        'HostKey /etc/ssh/host-keys/ssh_host_ed25519_key' \
        'HostKey /etc/ssh/host-keys/ssh_host_rsa_key' \
        > /etc/ssh/sshd_config.d/devbox.conf

USER ${USERNAME}
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
    | sh -s -- -y --no-modify-path --profile minimal --component clippy --component rustfmt

USER root
# Cargo shim: sccache for a worktree's cold build, then incremental for the inner
# loop (see cargo-shim.sh). Installed ahead of ~/.cargo/bin so plain `cargo` hits
# it; the shim calls the real cargo by absolute path.
COPY cargo-shim.sh /home/${USERNAME}/.local/bin/cargo
RUN chmod 0755 /home/${USERNAME}/.local/bin/cargo \
    && chown -R ${USERNAME}:${USERNAME} /home/${USERNAME}/.local

# Interactive shells get the shim, then cargo, on PATH; the entrypoint appends the
# CARGO_* vars here.
RUN printf 'export PATH=/home/%s/.local/bin:/home/%s/.cargo/bin:$PATH\n' "${USERNAME}" "${USERNAME}" > /etc/profile.d/devbox-path.sh

# Non-interactive SSH (`ssh devbox cargo build`) gets PATH from /etc/environment
# via pam_env, which runs after sshd reads ~/.ssh/environment and overrides it.
# The shim and cargo have to be here or they are invisible to non-login shells.
RUN sed -i "s|^PATH=\"|PATH=\"/home/${USERNAME}/.local/bin:/home/${USERNAME}/.cargo/bin:|" /etc/environment

COPY entrypoint.sh user-setup.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/user-setup.sh

EXPOSE 22
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["/usr/sbin/sshd", "-D", "-e"]
