# devbox

A containerized dev environment reachable over SSH, with a persistent
workspace, cargo/sccache caches, and Claude Code/Orca state that survive
rebuilds.

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
