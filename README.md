# devbox

A containerized dev environment reachable over SSH, with a persistent
workspace, cargo/sccache caches, and Claude Code/Orca state that survive
rebuilds.

**[`docs/setup.html`](docs/setup.html) is the full write-up** — open it in a
browser. It covers the topology, the boot sequence, how env and PATH reach
each kind of session, the Orca remote layout, the worktree convention, the
cargo shim, and why the container is what makes running agents with approvals
skipped a bounded risk. What follows here is the quick start.

## Preinstalled tooling

Beyond the base toolchain (Rust via rustup, Node LTS, `gh`, `sccache`, `mold`,
`ripgrep`, Claude Code):

| | |
| --- | --- |
| Shell / files | `fd`, `tree`, `bat`, `delta` (git-delta), `lsof`, `nc` (netcat-openbsd), `zstd`, `time` |
| Data | `jq`, `yq` (mikefarah), `sqlite3`, `duckdb` |
| Build / bench | `just`, `hyperfine` |
| Lint | `shellcheck`, `shfmt` |
| Security | `trivy`, `cargo-deny` |
| Cargo | `cargo-nextest`, `cargo-expand`, `cargo-machete` |

Versions are pinned as `ARG`s at the top of the `Dockerfile` for anything not
taken from the Ubuntu archive. `cargo expand` additionally needs a nightly
rustc — run `rustup toolchain install nightly --profile minimal` inside the box.

## Setup

1. **SSH key.** The container authenticates you with your host's public key,
   read from `~/.ssh/id_ed25519.pub` (see `docker-compose.yml`). If you don't
   already have one:

   ```sh
   ssh-keygen -t ed25519 -C "you@example.com"
   ```

   Accept the default path (`~/.ssh/id_ed25519`) — the compose file mounts
   that exact path read-only into the container on every start.

2. **Env file.** Copy `.env.example` to `.env` and fill in `GH_TOKEN`,
   `SUDO_PASSWORD`, and `CLAUDE_CODE_OAUTH_TOKEN` as needed. `.env` is
   gitignored.

3. **Build and start.**

   ```sh
   docker compose up -d --build
   ```

4. **SSH config.** Add a `devbox` host entry so `ssh devbox` just works:

   ```
   Host devbox
       HostName localhost
       User dev
       Port 2223
       IdentityFile ~/.ssh/id_ed25519
       ForwardAgent yes
       StrictHostKeyChecking no
       UserKnownHostsFile /dev/null
   ```

   The container's SSH host key is generated once on first start and kept on
   a volume, so it stays stable across rebuilds — `StrictHostKeyChecking no`
   / `UserKnownHostsFile /dev/null` just avoid local `known_hosts` noise from
   port 2223 being reused by different containers over time.

5. **Connect.**

   ```sh
   ssh devbox
   ```

## Worktrees and cargo

Clone each repo once under `~/workspace`, then add worktrees as siblings:

```sh
cd ~/workspace/<repo>
git worktree add ../<repo>-<name> -b <branch>
```

There is deliberately **no shared `CARGO_TARGET_DIR`** — a shared one made
every cargo invocation in the box serialize on cargo's per-target-dir build
lock, which reads as a hang under agent runs. Each worktree keeps its own
`./target`; sccache is what shares compiled dependencies between them.

`~/.local/bin/cargo` is a shim (`cargo-shim.sh`) that sits ahead of the real
cargo on PATH, because sccache and `CARGO_INCREMENTAL` are mutually exclusive:

- **Cold** — the first build in a worktree runs with `RUSTC_WRAPPER=sccache`
  and `CARGO_INCREMENTAL=0`, warming the dependency graph from the global
  cache. On success it drops a `.sccache-warmed` sentinel in the target dir.
- **Warm** — every later build runs with sccache off and
  `CARGO_INCREMENTAL=1`, for a fast edit-rebuild loop.

Warm a fresh worktree with `cargo build`, not `cargo check` — a cold `check`
only produces dep `.rmeta`, so the next `build` would have to codegen every
dependency with sccache already switched off. `cargo clean` removes the
sentinel, and the next build correctly starts cold again.

## Sandbox

Agents run in here with `--dangerously-skip-permissions`, which is only a
reasonable trade because the container bounds the damage. Nothing of the host
is mounted except `~/.ssh/id_ed25519.pub` (read-only, public half only), sudo
needs `SUDO_PASSWORD` and is disabled outright when that is unset, and there
is no docker socket, no `privileged`, and no added capabilities.

Still fully in reach, and worth knowing: everything in `~/workspace` including
uncommitted work, `GH_TOKEN` and its push access, `CLAUDE_CODE_OAUTH_TOKEN`,
and unrestricted network egress. Note also that `ForwardAgent yes` in the SSH
config above exposes your host SSH agent to the container for the life of a
session — git doesn't need it (that's what the `GH_TOKEN` credential helper is
for), so drop it if unattended agents run while you're logged in.
