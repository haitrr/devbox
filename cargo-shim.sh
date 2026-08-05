#!/usr/bin/env bash
# cargo shim — sccache for the cold build, incremental for the inner loop.
#
# Why: sccache and CARGO_INCREMENTAL are mutually exclusive (sccache refuses to
# run as a rustc wrapper when incremental is on). Their value is temporally
# disjoint, though:
#   * sccache only pays off on the FIRST build of a fresh worktree — it warms
#     the dependency graph from the global cache. After deps land in ./target,
#     cargo's fingerprint keeps them fresh and never re-invokes rustc for them,
#     so sccache does nothing on later builds.
#   * incremental only pays off on builds 2..N — it lets an edited local crate
#     recompile just its changed codegen units instead of the whole crate.
#
# So: cold build uses sccache (incremental off); once the worktree is warmed we
# switch to incremental (sccache off) for fast edit-rebuild loops. The switch is
# recorded by a sentinel inside the target dir, so it is one-directional per
# worktree (no 0<->1 toggling, which would thrash local-crate fingerprints).
#
# Installed at ~/.local/bin/cargo, ahead of ~/.cargo/bin on PATH. The real cargo
# (rustup's proxy) is called by absolute path so this never recurses.
#
# Caveats (see the PR discussion):
#   * The switch costs a one-time recompile of your local crates (turning
#     incremental on changes their rustc flags, invalidating their fingerprint).
#     Deps are unaffected — they are never incremental.
#   * Warm your worktree with `cargo build`, not `cargo check`. A cold `check`
#     only produces dep .rmeta; a later `build` (now with sccache off) would then
#     have to codegen every dep from scratch. `build` seeds both.
#   * Concurrency: if two builds start in the same worktree before the sentinel
#     is written, one may run cold while the other runs warm and they will
#     invalidate each other's local fingerprints once. Harmless but wasteful.
#   * `cargo clean` wipes the target dir including the sentinel, so the next
#     build correctly starts cold again.
set -euo pipefail

REAL_CARGO="${HOME:-/home/dev}/.cargo/bin/cargo"
if [ ! -x "$REAL_CARGO" ]; then
    # Fallback: the first cargo on PATH that is not this shim. `command -v` only
    # ever prints its first match (the shim itself), so grep-ing it out leaves
    # nothing — we have to walk PATH by hand and compare resolved paths.
    self="$(realpath -- "$0" 2>/dev/null || echo "$0")"
    REAL_CARGO=""
    saved_ifs="$IFS"; IFS=:
    for dir in $PATH; do
        cand="$dir/cargo"
        [ -x "$cand" ] || continue
        [ "$(realpath -- "$cand" 2>/dev/null || echo "$cand")" = "$self" ] && continue
        REAL_CARGO="$cand"; break
    done
    IFS="$saved_ifs"
fi
if [ -z "$REAL_CARGO" ] || [ ! -x "$REAL_CARGO" ]; then
    echo "cargo-shim: cannot locate the real cargo (checked ~/.cargo/bin/cargo and \$PATH)" >&2
    exit 127
fi

# First positional that is not a flag (-v), a toolchain override (+nightly), or
# the value consumed by a value-taking global flag. Without the skip,
# `cargo -Z unstable-options build` would latch onto unstable-options as the
# subcommand and pass straight through in the cold config.
subcmd=""
skip_next=0
for a in "$@"; do
    if [ "$skip_next" = 1 ]; then skip_next=0; continue; fi
    case "$a" in
        -Z|-C|--color|--config) skip_next=1; continue ;;
        -*|+*) continue ;;
        *) subcmd="$a"; break ;;
    esac
done

# Only compile-producing subcommands care about sccache-vs-incremental. nextest
# is here because CLAUDE.md mandates `cargo nextest run` for tests — omitting it
# would route the entire test inner loop through the cold config unconditionally.
case "$subcmd" in
    build|b|check|c|test|t|run|r|bench|clippy|rustc|doc|nextest) ;;
    *) exec "$REAL_CARGO" "$@" ;;   # fmt, tree, add, metadata, ... pass straight through
esac

# Codegen-producing subcommands only. check/clippy/doc emit metadata (no .rlib),
# so flipping on them turns sccache off before deps are ever codegen'd through it.
case "$subcmd" in
    build|b|test|t|run|r|bench|nextest) codegen=1 ;;
    *) codegen=0 ;;
esac

# Locate this build's target dir so the sentinel travels with it.
if [ -n "${CARGO_TARGET_DIR:-}" ]; then
    target_dir="$CARGO_TARGET_DIR"
else
    root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    target_dir="$root/target"
fi
sentinel="$target_dir/.sccache-warmed"

if [ -f "$sentinel" ]; then
    # Warm: fast inner loop. incremental on, sccache off.
    exec env -u RUSTC_WRAPPER CARGO_INCREMENTAL=1 "$REAL_CARGO" "$@"
fi

# Cold: warm the dependency graph from sccache. incremental off (required).
status=0
env RUSTC_WRAPPER=sccache CARGO_INCREMENTAL=0 "$REAL_CARGO" "$@" || status=$?
# Only flip to warm after a successful cold build, so a failed build retries cold.
if [ "$status" -eq 0 ] && [ "$codegen" = 1 ]; then
    mkdir -p "$target_dir"
    : > "$sentinel"
fi
exit "$status"
