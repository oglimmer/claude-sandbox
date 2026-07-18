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
    && rm -rf /var/lib/apt/lists/*

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
RUN npm install -g @anthropic-ai/claude-code \
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
