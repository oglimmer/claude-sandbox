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

# NOTE: settings.json is bind-mounted from ./claude-settings.json in this repo,
# so nothing here needs to seed it. Do not be tempted to rewrite it from this
# script with the usual write-temp-then-`mv` idiom: renaming over a bind-mounted
# file fails with EBUSY inside the container. Only in-place writes work.

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
