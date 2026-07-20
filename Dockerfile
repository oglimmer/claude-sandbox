# Sandbox image for running Claude Code in an isolated container.
# Debian-based Node image gives us the glibc + node runtime Claude Code needs.
FROM node:22-bookworm-slim

# ---- OS packages -----------------------------------------------------------
# git         : Claude Code drives git for most repos
# ca-certs    : TLS for npm / API calls
# curl, wget  : fetching things during tasks
# ripgrep     : fast search (Claude Code uses it heavily)
# less         : pager used by git / tools
# openssh     : cloning private repos over ssh (optional)
# build tools : native npm modules, general build tasks
# python3 + pip + venv : Python toolchain
# gnupg/apt-transport-https : needed to add the Adoptium (Temurin JDK) apt repo
# sudo         : lets the non-root user install extra tooling at runtime if needed
RUN apt-get update && apt-get install -y --no-install-recommends \
        git \
        ca-certificates \
        curl \
        wget \
        ripgrep \
        less \
        jq \
        openssh-client \
        build-essential \
        python3 \
        python3-pip \
        python3-venv \
        gnupg \
        apt-transport-https \
        sudo \
        tini \
        zsh \
        maven \
        xz-utils \
        shellcheck \
        xmlstarlet \
    && rm -rf /var/lib/apt/lists/*

# yamllint / pre-commit from PyPI rather than apt: bookworm ships versions old
# enough that repos pinning `minimum_pre_commit_version` fail. Debian marks the
# system Python "externally managed"; this image has no other Python consumer,
# so installing into it directly is fine.
RUN pip3 install --no-cache-dir --break-system-packages yamllint pre-commit

# ---- Languages: Go + JDK ---------------------------------------------------
# Node (from the base image) and Python (above) are already present.
# Go: install the official toolchain (distro packages lag well behind).
ARG GO_VERSION=1.23.5
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
        amd64) goarch=amd64 ;; \
        arm64) goarch=arm64 ;; \
        *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${goarch}.tar.gz" -o /tmp/go.tgz; \
    tar -C /usr/local -xzf /tmp/go.tgz; \
    rm /tmp/go.tgz; \
    /usr/local/go/bin/go version
ENV PATH=/usr/local/go/bin:${PATH}

# JDK: Eclipse Temurin (Adoptium) — modern LTS, multi-arch (amd64 + arm64).
ARG JDK_VERSION=21
RUN set -eux; \
    mkdir -p /etc/apt/keyrings; \
    curl -fsSL https://packages.adoptium.net/artifactory/api/gpg/key/public \
        | gpg --dearmor -o /etc/apt/keyrings/adoptium.gpg; \
    codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"; \
    echo "deb [signed-by=/etc/apt/keyrings/adoptium.gpg] https://packages.adoptium.net/artifactory/deb ${codename} main" \
        > /etc/apt/sources.list.d/adoptium.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends "temurin-${JDK_VERSION}-jdk"; \
    rm -rf /var/lib/apt/lists/*; \
    java -version

# ---- Docker CLI ------------------------------------------------------------
# Client only — no daemon in this image. It talks to the `dind` sidecar over TCP
# (DOCKER_HOST, set in docker-compose.yml), so the host's Docker stays isolated
# from anything the agent does.
RUN set -eux; \
    mkdir -p /etc/apt/keyrings; \
    curl -fsSL https://download.docker.com/linux/debian/gpg \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg; \
    codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"; \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian ${codename} stable" \
        > /etc/apt/sources.list.d/docker.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        docker-ce-cli docker-buildx-plugin docker-compose-plugin; \
    rm -rf /var/lib/apt/lists/*; \
    docker --version

# ---- kubectl ---------------------------------------------------------------
# Reads the host ~/.kube mounted read-only (see compose). Multi-arch.
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    ver="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"; \
    curl -fsSL "https://dl.k8s.io/release/${ver}/bin/linux/${arch}/kubectl" -o /usr/local/bin/kubectl; \
    chmod 0755 /usr/local/bin/kubectl; \
    kubectl version --client

# ---- GitHub CLI (gh) + GitLab CLI (glab) -----------------------------------
# Both authenticate non-interactively from an env var the wrapper injects from
# the host — gh reads GH_TOKEN, glab reads GITLAB_TOKEN (see oglimmer.sh and the
# environment: block in docker-compose.yml). No host config dir is mounted: on
# macOS gh keeps its token in the Keychain, so ~/.config/gh carries no token to
# copy — the resolved token is the only thing that reliably crosses over.
#
# gh has an official multi-arch apt repo (stays current within the pinned
# distro), same pattern as Docker/Adoptium above.
RUN set -eux; \
    mkdir -p /etc/apt/keyrings; \
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        -o /etc/apt/keyrings/githubcli-archive-keyring.gpg; \
    chmod 0644 /etc/apt/keyrings/githubcli-archive-keyring.gpg; \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends gh; \
    rm -rf /var/lib/apt/lists/*; \
    gh --version

# glab has no apt repo — pull its release tarball (multi-arch; ships bin/glab).
ARG GLAB_VERSION=1.108.0
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
        amd64) glab_arch=amd64 ;; \
        arm64) glab_arch=arm64 ;; \
        *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac; \
    tmp="$(mktemp -d)"; \
    curl -fsSL "https://gitlab.com/gitlab-org/cli/-/releases/v${GLAB_VERSION}/downloads/glab_${GLAB_VERSION}_linux_${glab_arch}.tar.gz" \
        -o "$tmp/glab.tgz"; \
    tar -xzf "$tmp/glab.tgz" -C "$tmp" bin/glab; \
    install -m 0755 "$tmp/bin/glab" /usr/local/bin/glab; \
    rm -rf "$tmp"; \
    glab --version

# ---- Code-aware CLI tools --------------------------------------------------
# The structural search/diff/validate toolkit the agent is told to prefer over
# regex-and-line based equivalents (see sandbox-CLAUDE.md, which documents these
# to Claude). Upstream release binaries — none of these are in Debian, or the
# Debian versions lag too far to be useful. Versions are pinned where the asset
# name carries one; the rest use the `latest/download` redirect.
ARG SD_VERSION=1.1.0
ARG DELTA_VERSION=0.19.2
ARG HYPERFINE_VERSION=1.20.0
ARG WATCHEXEC_VERSION=2.5.1
ARG TRUFFLEHOG_VERSION=3.95.9
ARG COMBY_VERSION=1.8.1
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
        amd64) triple=x86_64; scc_arch=x86_64 ;; \
        arm64) triple=aarch64; scc_arch=arm64 ;; \
        *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac; \
    tmp="$(mktemp -d)"; cd "$tmp"; \
    dl() { curl -fsSL "$1" -o "$2"; }; \
    \
    dl "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${arch}" /usr/local/bin/yq; \
    \
    dl "https://github.com/chmln/sd/releases/download/v${SD_VERSION}/sd-v${SD_VERSION}-${triple}-unknown-linux-musl.tar.gz" sd.tgz; \
    tar -xzf sd.tgz --strip-components=1 -C /usr/local/bin --wildcards '*/sd'; \
    \
    dl "https://github.com/Wilfred/difftastic/releases/latest/download/difft-${triple}-unknown-linux-gnu.tar.gz" difft.tgz; \
    tar -xzf difft.tgz -C /usr/local/bin difft; \
    \
    dl "https://github.com/dandavison/delta/releases/download/${DELTA_VERSION}/delta-${DELTA_VERSION}-${triple}-unknown-linux-gnu.tar.gz" delta.tgz; \
    tar -xzf delta.tgz --strip-components=1 -C /usr/local/bin --wildcards '*/delta'; \
    \
    dl "https://github.com/boyter/scc/releases/latest/download/scc_Linux_${scc_arch}.tar.gz" scc.tgz; \
    tar -xzf scc.tgz -C /usr/local/bin scc; \
    \
    dl "https://github.com/sharkdp/hyperfine/releases/download/v${HYPERFINE_VERSION}/hyperfine-v${HYPERFINE_VERSION}-${triple}-unknown-linux-gnu.tar.gz" hyperfine.tgz; \
    tar -xzf hyperfine.tgz --strip-components=1 -C /usr/local/bin --wildcards '*/hyperfine'; \
    \
    # musl, not gnu: the gnu build links against GLIBC 2.39 and bookworm has 2.36.
    dl "https://github.com/watchexec/watchexec/releases/download/v${WATCHEXEC_VERSION}/watchexec-${WATCHEXEC_VERSION}-${triple}-unknown-linux-musl.tar.xz" watchexec.txz; \
    tar -xJf watchexec.txz --strip-components=1 -C /usr/local/bin --wildcards '*/watchexec'; \
    \
    dl "https://github.com/trufflesecurity/trufflehog/releases/download/v${TRUFFLEHOG_VERSION}/trufflehog_${TRUFFLEHOG_VERSION}_linux_${arch}.tar.gz" th.tgz; \
    tar -xzf th.tgz -C /usr/local/bin trufflehog; \
    \
    # comby publishes an x86_64 Linux binary only; on arm64 it is simply absent
    # and sandbox-CLAUDE.md tells the agent to fall back to ast-grep/sd.
    if [ "$arch" = amd64 ]; then \
        dl "https://github.com/comby-tools/comby/releases/download/${COMBY_VERSION}/comby-${COMBY_VERSION}-x86_64-linux" /usr/local/bin/comby; \
    fi; \
    \
    cd /; rm -rf "$tmp"; \
    chmod 0755 /usr/local/bin/yq /usr/local/bin/sd /usr/local/bin/difft \
               /usr/local/bin/delta /usr/local/bin/scc /usr/local/bin/hyperfine \
               /usr/local/bin/watchexec /usr/local/bin/trufflehog; \
    [ "$arch" != amd64 ] || chmod 0755 /usr/local/bin/comby; \
    yq --version; sd --version; difft --version; delta --version; \
    scc --version; hyperfine --version; watchexec --version; trufflehog --version

# Documents the toolkit above to Claude. The entrypoint installs it as
# ~/.claude/CLAUDE.md (the user-level memory file), optionally with a profile's
# own CLAUDE.md appended. Copied while still root — /opt/sandbox has to be
# world-readable for the non-root user to read it back out at runtime.
RUN mkdir -p /opt/sandbox && chmod 0755 /opt/sandbox
COPY --chmod=0644 sandbox-CLAUDE.md /opt/sandbox/CLAUDE.md

# Login shells (bash -l) re-source /etc/profile and reset PATH, dropping the
# Docker ENV additions below. Mirror them into a profile.d script so `go` and
# the user npm bins resolve in interactive login shells too.
RUN printf '%s\n' \
    'export GOPATH="$HOME/go"' \
    'export PATH="$HOME/.npm-global/bin:$HOME/go/bin:/usr/local/go/bin:$HOME/.config/custom-script-bin:$PATH"' \
    > /etc/profile.d/sandbox-paths.sh

# ---- Non-root user ---------------------------------------------------------
# Running as a normal user keeps the sandbox from doing root-level damage.
# UID/GID 1000 matches the typical host user so bind-mounted files stay writable.
ARG USERNAME=claude
ARG USER_UID=1000
ARG USER_GID=1000
# The node base image already ships a `node` user at UID/GID 1000, so free that
# slot first, then create our own user idempotently.
RUN if getent passwd ${USER_UID} >/dev/null; then userdel -r "$(getent passwd ${USER_UID} | cut -d: -f1)" 2>/dev/null || true; fi \
    && if getent group ${USER_GID} >/dev/null; then groupdel "$(getent group ${USER_GID} | cut -d: -f1)" 2>/dev/null || true; fi \
    && groupadd --gid ${USER_GID} ${USERNAME} \
    && useradd --uid ${USER_UID} --gid ${USER_GID} --create-home --shell /bin/bash ${USERNAME} \
    && echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${USERNAME} \
    && chmod 0440 /etc/sudoers.d/${USERNAME}

# Persist Claude Code auth/config here; mount a volume over it (see compose).
ENV CLAUDE_CONFIG_DIR=/home/${USERNAME}/.claude
ENV NODE_OPTIONS=--max-old-space-size=4096
# Install global npm packages into a user-writable prefix so Claude Code can
# self-update from inside the sandbox (a root-owned global install can't).
ENV NPM_CONFIG_PREFIX=/home/${USERNAME}/.npm-global
# GOPATH defaults to $HOME/go; put its bin (and the npm prefix bin) on PATH so
# `go install`ed tools and global npm bins are runnable.
ENV GOPATH=/home/${USERNAME}/go
# ~/.config/custom-script-bin is bind-mounted from the host and holds `git-llm`,
# which the host git alias `git ai` shells out to.
ENV PATH=/home/${USERNAME}/.npm-global/bin:/home/${USERNAME}/go/bin:/home/${USERNAME}/.config/custom-script-bin:${PATH}

# ---- Claude Code -----------------------------------------------------------
# Installed as the non-root user into the writable prefix above.
USER ${USERNAME}
RUN npm install -g @anthropic-ai/claude-code @ast-grep/cli \
    && npm cache clean --force

# Pre-create the config dir owned by the claude user. A named volume mounted
# here inherits this ownership/permissions when first created, so the non-root
# user can actually write credentials/config into it (a fresh named volume is
# otherwise root-owned and unwritable to uid 1000 -> "Auth token: none").
RUN mkdir -p ${CLAUDE_CONFIG_DIR} && chmod 700 ${CLAUDE_CONFIG_DIR}

# Pre-create the bind-mount targets as the non-root user. Docker creates missing
# mount points owned by root, which would leave ~/.config unwritable for
# everything *else* that wants to live there.
RUN mkdir -p /home/${USERNAME}/.config/git \
             /home/${USERNAME}/.config/custom-script-bin \
             /home/${USERNAME}/.ssh \
             /home/${USERNAME}/.kube \
             /home/${USERNAME}/.m2 \
    && chmod 700 /home/${USERNAME}/.ssh

WORKDIR /workspace

# Entrypoint seeds the git identity from GIT_USER_NAME/GIT_USER_EMAIL env vars.
COPY --chmod=0755 entrypoint.sh /usr/local/bin/entrypoint.sh

# tini reaps zombies so long-running interactive sessions stay clean; our
# entrypoint script runs under it and then execs the CMD.
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]

# Launch straight into Claude Code with permission prompts disabled.
# This is safe *because* the container is the sandbox: the agent can only touch
# the mounted workspace, runs non-root, and can't escalate. Never pass this flag
# on a bare host. Runs as the non-root `claude` user (the flag refuses root).
#
# $CLAUDE_ARGS is appended unquoted so extra flags can be injected from the
# environment without restating the command — e.g. CLAUDE_ARGS=-c to continue
# the last session in this working directory. It is deliberately word-split;
# it's for flags, not for arguments containing spaces.
#
# $CLAUDE_PROFILE_ARGS is assembled by the entrypoint from the mounted profile
# (--mcp-config / --plugin-dir / --settings) and comes first, so a flag passed
# per-run through CLAUDE_ARGS still wins.
CMD ["sh", "-c", "exec claude --dangerously-skip-permissions $CLAUDE_PROFILE_ARGS $CLAUDE_ARGS"]
