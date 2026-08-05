<!--
Template. Copy this to CLAUDE_box.md, edit it, and point CLAUDE_BOX_MD in .env
at it:

    cp CLAUDE_box.example.md CLAUDE_box.md
    echo 'CLAUDE_BOX_MD=./CLAUDE_box.md' >> .env
    docker compose up -d

user-setup.sh copies it to ~/.claude/CLAUDE.md on every start, so it applies to
every project inside the box and a change takes a restart, not a rebuild. The
host file wins: edits made to ~/.claude/CLAUDE.md inside the container are
overwritten the next time the box comes up. CLAUDE_box.md itself is gitignored,
so what you put in it stays out of the repo.

Everything below is example content — replace it. This is an HTML comment, so
it stays invisible if you leave it in place.
-->

# Global Guidelines

## Environment

- This is a devbox container reached over SSH. There is no display and no
  browser — never try to verify anything visually.
- `sudo` needs the password from `SUDO_PASSWORD`, and is disabled outright when
  that is unset. For root work, tell me to run `docker exec -u root devbox ...`
  from the host rather than trying to escalate in here.

## Git

- Commit identity comes from `.env` and is rewritten on every start. Don't set
  it with `git config --global` inside the box; the next rebuild drops it.

## Testing

- Keep test concurrency low (`--test-threads`, `-j`). The container shares the
  host's memory and a full-width test run gets OOM-killed.
