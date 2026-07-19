#!/bin/sh
# Container entrypoint: seed the git identity from env vars (if provided) before
# handing off to the real command. Values come from the host via docker compose
# (see .env / GIT_USER_NAME + GIT_USER_EMAIL). Writing them into the container's
# own ~/.gitconfig keeps macOS-specific host config (difftools, credential
# helpers) out of the sandbox, and leaves the config writable inside.
set -e

# `git config --global` writes to $XDG_CONFIG_HOME/git/config when ~/.gitconfig
# is absent — and that path is the host's config, bind-mounted read-only. Make
# sure the container's own ~/.gitconfig exists first so it wins as the write
# target; the host file is still *read* on top of it (that's where aliases come
# from).
[ -f "${HOME}/.gitconfig" ] || : > "${HOME}/.gitconfig"

if [ -n "${GIT_USER_NAME}" ]; then
    git config --global user.name "${GIT_USER_NAME}"
fi
if [ -n "${GIT_USER_EMAIL}" ]; then
    git config --global user.email "${GIT_USER_EMAIL}"
fi

# A couple of sensible defaults for working in a fresh sandbox; only set if the
# user hasn't already configured them.
git config --global --get init.defaultBranch >/dev/null 2>&1 || git config --global init.defaultBranch main
git config --global --get --path safe.directory >/dev/null 2>&1 || git config --global --add safe.directory /workspace

# The host's ~/.config/git is bind-mounted read-only; git reads it in addition
# to the writable ~/.gitconfig above, which is where the `ai` alias comes from.
# macOS-only bits in it (difftool paths) are harmless — they just never fire.

# kubectl's cache dir (KUBECACHEDIR) — ~/.kube itself is read-only.
mkdir -p "${KUBECACHEDIR:-$HOME/.cache/kube}"

# ---- Settings --------------------------------------------------------------
# Seed the profile's settings.json from ./claude-settings.json on first run.
# It can't be bind-mounted into place: ~/.claude is itself a host bind mount,
# and Docker Desktop refuses to create a nested mountpoint inside one. Only
# seeded when absent, so the CLI's own changes (theme, etc.) survive restarts
# and each profile can diverge. Delete the file to pick up a changed baseline.
#
# -s, not -f: a failed nested-mount attempt leaves a 0-byte stub behind, and an
# empty settings.json is not a setting the user chose.
if [ -f /mnt/claude-settings.json ] && [ ! -s "${HOME}/.claude/settings.json" ]; then
    cp /mnt/claude-settings.json "${HOME}/.claude/settings.json"
fi

# ---- User-level CLAUDE.md --------------------------------------------------
# /opt/sandbox/CLAUDE.md is baked into the image and documents the CLI toolkit
# it ships (ast-grep, difft, yq, ...) so the agent actually reaches for it.
# Claude Code only reads user-level memory from ~/.claude/CLAUDE.md, which lives
# in the per-profile bind mount, so it gets written on every start rather than
# seeded once — the doc has to track the image, not the volume.
#
# A profile can add its own instructions by dropping a CLAUDE.md into its
# profile dir; it is appended after the image's (see profiles/README.md).
if [ -f /opt/sandbox/CLAUDE.md ]; then
    mkdir -p "${HOME}/.claude"
    cp /opt/sandbox/CLAUDE.md "${HOME}/.claude/CLAUDE.md"
    if [ -f /mnt/profile/CLAUDE.md ]; then
        printf '\n' >> "${HOME}/.claude/CLAUDE.md"
        cat /mnt/profile/CLAUDE.md >> "${HOME}/.claude/CLAUDE.md"
    fi
fi

# ---- Statusline -----------------------------------------------------------
# The host's ~/.claude/statusline is staged read-only at /mnt/host-statusline.
# Copy it into ~/.claude/statusline (the path statusline.sh hardcodes when it
# looks for Config.toml) so the config cache it writes next to Config.toml
# lands on a writable filesystem. Re-copied on every start, so host-side edits
# to Config.toml show up after a restart rather than being pinned by the
# ~/.claude volume.
if [ -d /mnt/host-statusline ]; then
    mkdir -p "${HOME}/.claude/statusline"
    cp -a /mnt/host-statusline/. "${HOME}/.claude/statusline/" 2>/dev/null || true
fi

# ---- Per-workspace profile -------------------------------------------------
# profiles/common and profiles/$CLAUDE_PROFILE are staged read-only at
# /mnt/profile-common and /mnt/profile (see profiles/README.md). Everything here
# is optional: with an empty profile the sandbox behaves as it did before.
#
# Skills have to live at ~/.claude/skills for Claude Code to discover them, so
# they get copied rather than mounted. The tree is rebuilt from scratch on every
# start — otherwise skills from a previously-selected profile would linger in
# the volume and silently apply to the wrong workspace. common/ is copied first
# so a profile can shadow a common skill by using the same name.
rm -rf "${HOME}/.claude/skills"
mkdir -p "${HOME}/.claude/skills"
for _skills in /mnt/profile-common/skills /mnt/profile/skills; do
    [ -d "${_skills}" ] || continue
    cp -a "${_skills}/." "${HOME}/.claude/skills/" 2>/dev/null || true
done

# The rest are passed to the CLI as flags, read directly from the read-only
# mount. CLAUDE_PROFILE_ARGS is picked up by the CMD in the Dockerfile, ahead of
# CLAUDE_ARGS so a per-run flag can still override.
CLAUDE_PROFILE_ARGS=""
if [ -f /mnt/profile/mcp.json ]; then
    CLAUDE_PROFILE_ARGS="${CLAUDE_PROFILE_ARGS} --mcp-config /mnt/profile/mcp.json"
fi
if [ -d /mnt/profile/plugins ]; then
    CLAUDE_PROFILE_ARGS="${CLAUDE_PROFILE_ARGS} --plugin-dir /mnt/profile/plugins"
fi
if [ -f /mnt/profile/settings.json ]; then
    CLAUDE_PROFILE_ARGS="${CLAUDE_PROFILE_ARGS} --settings /mnt/profile/settings.json"
fi
export CLAUDE_PROFILE_ARGS

# ---- SSH ------------------------------------------------------------------
# The host's ~/.ssh is staged read-only at /mnt/host-ssh. Copy it into ~/.ssh so
# ssh can write known_hosts, fix up the permissions it insists on, and neutralise
# the macOS-only directives that would otherwise make OpenSSH refuse to start:
#   UseKeychain          - Apple extension, unknown to Linux OpenSSH
#   Include ~/.orbstack  - OrbStack path that doesn't exist in the container
# Docker Desktop hands the forwarded agent socket over as root:root 0660, which
# the non-root user can't open. Take ownership of it (the socket only exists
# inside this container's mount namespace).
if [ -S "${SSH_AUTH_SOCK:-}" ] && [ ! -w "${SSH_AUTH_SOCK}" ]; then
    sudo chown "$(id -u):$(id -g)" "${SSH_AUTH_SOCK}" 2>/dev/null || true
fi

if [ -d /mnt/host-ssh ]; then
    cp -a /mnt/host-ssh/. "${HOME}/.ssh/" 2>/dev/null || true
    chmod 700 "${HOME}/.ssh"
    find "${HOME}/.ssh" -type f ! -name '*.pub' -exec chmod 600 {} +
    if [ -f "${HOME}/.ssh/config" ]; then
        sed -i 's|^\([[:space:]]*Include[[:space:]].*orbstack.*\)$|# \1|' "${HOME}/.ssh/config"
        # IgnoreUnknown only applies to keywords appearing *after* it.
        printf '%s\n' 'IgnoreUnknown UseKeychain,AddKeysToAgent,IdentityAgent' \
            | cat - "${HOME}/.ssh/config" > "${HOME}/.ssh/config.tmp"
        mv "${HOME}/.ssh/config.tmp" "${HOME}/.ssh/config"
        chmod 600 "${HOME}/.ssh/config"
    fi
fi

exec "$@"
