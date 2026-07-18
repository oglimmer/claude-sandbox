# claude-sandbox

A disposable Docker sandbox for running [Claude Code](https://claude.com/claude-code)
in an isolated container instead of directly on your host. Claude Code runs as a
non-root user, confined to a mounted workspace, so an agent task can't touch the
rest of your machine.

## What's in the box

| File                 | Purpose                                                              |
| -------------------- | ------------------------------------------------------------------- |
| `Dockerfile`         | `node:22-bookworm-slim` + language toolchains + Claude Code CLI      |
| `docker-compose.yml` | Build + run config, volume mounts, optional hardening               |
| `entrypoint.sh`      | Seeds git identity, fixes up the ssh config, prepares cache dirs    |
| `claude-settings.json` | Claude Code settings for the sandbox (mounted read-write)          |
| `.env.example`       | Optional `ANTHROPIC_API_KEY`, git identity, `WORKSPACE_DIR`         |
| `docker-compose.override.yml.example` | Template for machine-specific mounts               |
| `workspace/`         | The code Claude works on (bind-mounted into the container)          |

## Language toolchains

The image bundles four language runtimes so Claude can build/test polyglot projects:

| Language | Version        | Source                              |
| -------- | -------------- | ----------------------------------- |
| Node.js  | 22.x           | base image (`node:22-bookworm-slim`) |
| Python   | 3.11 + pip/venv | Debian bookworm                     |
| Go       | 1.23.5         | official tarball (`/usr/local/go`)  |
| Java     | Temurin JDK 21 | Adoptium apt repo                   |
| Maven    | 3.8.7          | Debian bookworm                     |

Plus the CLIs the mounts below need: `docker` (+ buildx/compose plugins),
`kubectl`, and `zsh` (host helper scripts often carry a zsh shebang).

Override the pinned versions at build time, e.g.:

```bash
docker compose build --build-arg GO_VERSION=1.24.0 --build-arg JDK_VERSION=17
```

`GOPATH` is `$HOME/go`, and `$HOME/go/bin` + the npm global bin dir are on `PATH`
(in both login and non-login shells).

## Requirements

- Docker Engine with the Compose plugin (`docker compose`)

## Quick start

```bash
# 1. Build the image
docker compose build

# 2. Launch straight into Claude Code (interactive)
docker compose run --rm claude
```

The default command is `claude --dangerously-skip-permissions`, so Claude Code
runs without stopping to ask for approval on each action. **This is only safe
because the container itself is the sandbox** — the agent is confined to the
mounted workspace, runs non-root, and can't escalate. Never use that flag on a
bare host.

On first launch, run `/login` inside the CLI to authenticate via OAuth. Your
login is stored in the `claude-config` named volume and survives rebuilds.

> Use `docker compose run --rm claude` (not `up -d`) — it wires up an
> interactive terminal for the CLI and removes the container on exit. To get a
> plain shell instead, run `docker compose run --rm claude bash`.

Put the code you want Claude to work on in `./workspace` (or repoint that bind
mount at an existing project — see below).

To stop and clean up:

```bash
docker compose down          # stop, keep the config volume
docker compose down -v       # stop and wipe login/config too
```

## Continuing a session

Session transcripts live in `~/.claude/projects/` inside the `claude-config`
volume, so they outlive any single container. The default command appends
`$CLAUDE_ARGS`, which is how you pass `-c` without restating the whole thing:

```bash
CLAUDE_ARGS=-c docker compose run --rm claude       # continue the last session
CLAUDE_ARGS=--resume docker compose run --rm claude # pick a session from a list
```

Or override the command outright:

```bash
docker compose run --rm claude claude --dangerously-skip-permissions -c
```

`$CLAUDE_ARGS` is word-split on purpose — fine for flags, not for arguments
containing spaces. For those, override the command.

> **Sessions are keyed by working directory, and `working_dir` is always
> `/workspace`.** So every project you mount shares one session history under
> `~/.claude/projects/-workspace/`. After repointing `WORKSPACE_DIR`, `-c` will
> happily resume a conversation about the *previous* project. Use
> `--resume` to pick deliberately when you've switched.

`docker compose down -v` wipes the volume and every stored session with it.

## Authentication

Two options:

1. **Interactive OAuth (recommended)** — just run `claude` and use `/login`.
   Nothing to configure.
2. **API key** — copy `.env.example` to `.env` and set `ANTHROPIC_API_KEY`.
   Compose picks it up automatically.

```bash
cp .env.example .env
# edit .env, then:
docker compose up -d
```

## Git identity

Commits made inside the sandbox need a name/email. The container's entrypoint
seeds git's global config from two env vars, which you take over from your host:

```bash
# populate .env with your host's git identity (run once)
{
  echo "GIT_USER_NAME=$(git config --global user.name)"
  echo "GIT_USER_EMAIL=$(git config --global user.email)"
} >> .env
```

`docker compose` reads `.env` automatically and the entrypoint runs
`git config --global user.name/email` on every start. This copies **only** the
name and email — not the host's macOS-specific bits (difftool paths, keychain
credential helpers), and the container's git config stays writable.

> A repo with its own local `user.name`/`user.email` (e.g. your mounted project)
> keeps that identity — local config always overrides the seeded global one.

> The host's `~/.gitconfig` is deliberately *not* mounted — it tends to name
> host-only paths (difftool binaries, keychain credential helpers) that don't
> exist in a Linux container.

## Working on your own repo

Point `WORKSPACE_DIR` at it in `.env` — both services read that variable, and
they must agree (see [Docker in Docker](#docker-in-docker)):

```bash
echo "WORKSPACE_DIR=$HOME/dev/my-project" >> .env
```

## Host home directories

These are wired up in `docker-compose.yml` by default:

| Host path                    | In container                   | Mode | Notes |
| ---------------------------- | ------------------------------ | ---- | ----- |
| `~/.ssh`                     | `/mnt/host-ssh` → `~/.ssh`     | ro → copy | Copied in by the entrypoint (see below) |
| `~/.kube`                    | `~/.kube`                      | ro   | `KUBECACHEDIR` redirects the discovery cache to a writable dir |
| `~/.m2`                      | `~/.m2`                        | rw   | Shared artifact cache — Maven must be able to write it |
| `~/.config/git`              | `~/.config/git`                | ro   | Global git aliases and ignore rules |
| `~/.claude/statusline`       | `/mnt/host-statusline` → `~/.claude/statusline` | ro → copy | Copied in by the entrypoint (see below) |

### Statusline

The host's statusline is shared with the sandbox, so the prompt looks the same
in both. It is staged read-only and **copied** into `~/.claude/statusline` by
the entrypoint, for two reasons:

- `statusline.sh` compiles `Config.toml` into a cache file (`.Config.cache.sh`)
  written *next to* the config, which a read-only mount would break.
- The host runs this script on every prompt refresh, so the sandbox must not be
  able to edit it — same reasoning as `settings.json`.

The copy happens on every container start, so host-side `Config.toml` edits
land after a restart rather than being pinned by the `~/.claude` volume.
`claude-settings.json` points at it with `/bin/bash` (Linux), not the host's
Homebrew bash.

### Machine-specific mounts

Anything beyond that — your own script directories, other credential stores —
goes in `docker-compose.override.yml`, which Compose merges automatically and
which is gitignored, so local paths stay out of commits:

```bash
cp docker-compose.override.yml.example docker-compose.override.yml
```

The `.example` file covers the fiddly case: a git alias that shells out to a
helper script. The script must be on the container's `PATH`, and if it's a
**symlink**, its absolute target path has to resolve inside the container too —
so that target gets mounted at the identical path.

### Git config

There is no `~/.git` on a host — the aliases live in `~/.config/git/config`.
Git reads that file **in addition to** `~/.gitconfig`, so the container mounts
the host's XDG config read-only for aliases while keeping its own writable
`~/.gitconfig` for identity and `safe.directory`. The entrypoint creates that
`~/.gitconfig` before writing to it, otherwise `git config --global` would fall
through to the read-only host file and fail to start the container.

Any macOS-only entries in that config (GUI difftool paths, for instance) come
along but never fire.

### SSH

`~/.ssh` is staged read-only at `/mnt/host-ssh` and **copied** into `~/.ssh` on
start rather than mounted directly, because the host config isn't portable:

- `UseKeychain` is an Apple extension — Linux OpenSSH refuses to start on it.
  The entrypoint prepends `IgnoreUnknown UseKeychain,…`.
- `Include ~/.orbstack/ssh/config` doesn't exist in the container; it gets
  commented out.
- Copying also lets ssh append to `known_hosts`.

**The GitHub key is passphrase-protected and unlocked from the macOS Keychain,
so the key file alone is useless inside Linux.** The compose file forwards the
host ssh-agent instead (Docker Desktop's `/run/host-services/ssh-auth.sock`) —
signing happens on the host and the passphrase never enters the container. Load
the key into the agent once per host login:

```bash
ssh-add --apple-load-keychain    # then: ssh-add -l   to confirm
```

Without this you'll get `Permission denied (publickey)`. Docker Desktop hands
the socket over as `root:root 0660`, so the entrypoint `chown`s it to the
container user.

> If you keep several keys, check which identity the container actually
> presents before pushing — a passphrase-less key will be picked up silently
> and may belong to a different account than the one you expect:
>
> ```bash
> docker compose exec claude ssh -T git@github.com
> ```

### Kubernetes

`~/.kube` is mounted **read-only** on purpose: every context in it is
potentially production, and ro also stops `kubectl config use-context` from
silently changing what a later command hits. Remote-server contexts work
as-is. A context pointing at `127.0.0.1` (a cluster running on the Mac
itself) needs
rewriting to `host.docker.internal` — that hostname is mapped for you via
`extra_hosts`.

## Docker in Docker

A `dind` sidecar (`docker:28-dind`, privileged) runs a Docker daemon that is
completely separate from the host's. The `claude` container gets the CLI only
and talks to it via `DOCKER_HOST=tcp://dind:2375` on the private compose
network — nothing is published to the host, so there's no TLS to manage.

**The host socket is deliberately not mounted.** `/var/run/docker.sock` inside
the sandbox would be equivalent to host root: the agent could
`docker run --privileged -v /:/host` and walk straight out. The whole point of
this repo is that it can't.

The workspace is bind-mounted into **both** containers at the same path
(`/workspace`), because `docker run -v /workspace/x:/y` is resolved by the
*daemon*, not the CLI. If you repoint the workspace, change it in both services
— or just set `WORKSPACE_DIR` in `.env`, which both read:

```bash
echo "WORKSPACE_DIR=$HOME/dev/my-project" >> .env
```

Images pulled/built inside the sandbox live in the `dind-data` volume and don't
touch the host's image store (`docker compose down -v` wipes them).

## Sandbox hardening

The default setup runs as a **non-root user** and confines file access to the
mounted volumes, but the container still has full network and API access. For
stronger isolation, uncomment the hardening block in `docker-compose.yml`:

| Setting                        | Effect                                        |
| ------------------------------ | --------------------------------------------- |
| `mem_limit` / `cpus` / `pids_limit` | Cap resources so a runaway task can't starve the host |
| `no-new-privileges:true`       | Prevent privilege escalation                  |
| `read_only: true` + `tmpfs`    | Read-only root filesystem; only volumes writable |

> **Note:** `network_mode: none` is no longer an option — the `claude`
> container needs the compose network to reach the `dind` daemon (and Claude
> Code needs network access to reach the API anyway).
>
> `no-new-privileges:true` breaks the entrypoint's `sudo chown` of the
> forwarded ssh-agent socket. Enable one or the other, not both.

The UID/GID default to `1000` to match a typical host user so bind-mounted files
stay writable. If your host user differs, adjust the `USER_UID` / `USER_GID`
build args in `docker-compose.yml`.

## Tips

- Get a plain shell in the sandbox: `docker compose run --rm claude bash`
- Run Claude Code *with* permission prompts (override the default):
  `docker compose run --rm claude claude`
- Run a long-lived container you can exec into repeatedly:
  `docker compose run -d --name claude-sandbox claude sleep infinity`, then
  `docker exec -it claude-sandbox claude`
- Rebuild after changing the Dockerfile: `docker compose build --no-cache`
