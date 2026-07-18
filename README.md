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
| `claude-settings.json` | Baseline Claude Code settings, seeded into each profile on first run |
| `oglimmer.sh`        | Manages profiles and runs the sandbox (`list`, `new`, `run`, `doctor`) |
| `.env.example`       | Optional `ANTHROPIC_API_KEY`, git identity, default profile         |
| `docker-compose.override.yml.example` | Template for machine-specific mounts               |
| `workspace/`         | The code Claude works on (bind-mounted into the container)          |
| `profiles/`          | Per-workspace skills, plugins and MCP servers (versioned)           |
| `profile-state/`     | Per-profile login, session history and `.claude.json` (gitignored)  |

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
./oglimmer.sh run
```

Use the script rather than `docker compose run` directly for the first launch.
A fresh clone has no `profile-state/default/`, and compose would create that
bind-mount source as **root** — leaving you logged out of a profile you can't
write to. `./oglimmer.sh run` creates it as you, and refuses a profile name it
doesn't recognise instead of silently starting an empty one. Afterwards
`docker compose run --rm claude` works fine.

The default command is `claude --dangerously-skip-permissions`, so Claude Code
runs without stopping to ask for approval on each action. **This is only safe
because the container itself is the sandbox** — the agent is confined to the
mounted workspace, runs non-root, and can't escalate. Never use that flag on a
bare host.

On first launch, run `/login` inside the CLI to authenticate via OAuth. Your
login is stored in `profile-state/<profile>/` on the host and survives rebuilds.
It is gitignored — that directory holds the credential.

> Use `docker compose run --rm claude` (not `up -d`) — it wires up an
> interactive terminal for the CLI and removes the container on exit. To get a
> plain shell instead, run `docker compose run --rm claude bash`.

Put the code you want Claude to work on in `./workspace` (or repoint that bind
mount at an existing project — see below).

To stop and clean up:

```bash
docker compose down          # stop
docker compose down -v       # stop and wipe the dind image cache
```

Neither touches your login or sessions — those are host directories now. To
reset a profile (and log it out), delete `profile-state/<profile>/`.

## Continuing a session

Session transcripts live in `profile-state/<profile>/projects/`, so they outlive
any container. Anything after `run` is handed to Claude Code:

```bash
./oglimmer.sh run -c            # continue the last session in this profile
./oglimmer.sh run --resume      # pick a session from a list
```

Script options go *before* the command (`./oglimmer.sh -v run -c`); everything
after `run` belongs to Claude Code.

Without the script it's the `$CLAUDE_ARGS` passthrough that the container's
default command appends:

```bash
CLAUDE_ARGS=-c docker compose run --rm claude
```

`$CLAUDE_ARGS` is word-split on purpose — fine for flags, not for arguments
containing spaces. For those, override the command outright:

```bash
docker compose run --rm claude claude --dangerously-skip-permissions -c
```

> Sessions are keyed by working directory, and `working_dir` is always
> `/workspace`. Per-profile state is what stops that from mattering: each profile
> owns one workspace, so `-c` resumes that workspace's history. Point a profile
> at a different directory (with `-w`, say) and `-c` will happily resume a
> conversation about the other one — `doctor` flags two profiles sharing a
> directory for the same reason.

`docker compose down -v` wipes the dind image cache, not your sessions — those
are host directories now. To reset a profile, delete `profile-state/<profile>/`
(which also logs it out).

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

Give it a profile — the profile records the directory, so from then on its name
is all you need:

```bash
./oglimmer.sh new my-project ~/dev/my-project
./oglimmer.sh -p my-project run
```

## Profiles

Each workspace gets its own skills, plugins and MCP servers — and owns the
directory it works on, recorded in `profiles/<name>/workspace` and mounted at
`/workspace` by both services (see [Docker in Docker](#docker-in-docker)).

| In the profile | Reaches Claude Code as |
| -------------- | ---------------------- |
| `skills/`      | copied into `~/.claude/skills` (after `profiles/common/skills`, so it can shadow by name) |
| `plugins/`     | `--plugin-dir` |
| `mcp.json`     | `--mcp-config` |
| `settings.json`| `--settings`, layered over `claude-settings.json` |

Everything is optional — an empty profile behaves exactly like the sandbox did
before profiles existed. MCP servers can equally be added from inside with
`claude mcp add`; those persist in `profile-state/<profile>/`, because
`CLAUDE_CONFIG_DIR` keeps `.claude.json` there. Configuring from outside via
`mcp.json` is usually easier to reproduce and review.

Session history and login live in `profile-state/<profile>/` and are therefore
also per profile. That is deliberate: every workspace mounts at `/workspace`, so
a shared state directory would make Claude Code treat unrelated repos as one
project and `CLAUDE_ARGS=-c` would resume the wrong session. A fresh profile
starts logged out — run `/login` once.

### Managing profiles

`./oglimmer.sh` handles the bookkeeping — creating profiles, editing `mcp.json`,
and showing what a workspace actually gets:

```bash
./oglimmer.sh list                      # skills, plugins and MCP for the active profile
./oglimmer.sh profiles                  # every profile, active one marked
./oglimmer.sh new my-api ~/dev/my-api   # profile + workspace + state directory
./oglimmer.sh workspace my-api          # which directory does it work on?
./oglimmer.sh workspace my-api ~/dev/v2 # repoint it
./oglimmer.sh mcp-add my-api playwright -- npx -y @playwright/mcp@latest
./oglimmer.sh skill-add common ~/.claude/skills/renovate-config
./oglimmer.sh doctor                    # find the usual breakages
```

### Switching profiles

`-p` picks a profile for one command, without touching `.env`:

```bash
./oglimmer.sh -p my-api run -c      # run my-api, continue its last session
./oglimmer.sh -p my-api list        # inspect it
```

Switching profiles switches the workspace with it — that pairing is the point.
For a lasting change, set `CLAUDE_PROFILE` in `.env`;
`CLAUDE_PROFILE=my-api ./oglimmer.sh run` works too. Precedence is `-p` >
environment > `.env` > `default`, matching what docker compose itself does.

To point a profile at a different directory for one run, use `-w`:

```bash
./oglimmer.sh -p my-api -w ~/dev/scratch run
```

To change it for good, `workspace`:

```bash
./oglimmer.sh workspace my-api ~/dev/my-api-v2
```

It validates like `new` does, and warns if the profile already has session
history — that history is keyed by the `/workspace` mount point, not the repo,
so it stays behind and `run -c` would resume a conversation about the old
directory. For a genuinely different project, prefer a second profile.

`run` refuses an unknown profile, and a workspace that doesn't exist, rather
than letting compose create either as root and starting you in an empty tree.

`doctor` catches what otherwise fails silently: a profile with no workspace or a
workspace that has gone missing, two profiles sharing one directory, invalid
`mcp.json`, `${VAR}` references that aren't set in `.env` or lack a passthrough
in `docker-compose.yml`, root-owned directories compose created, skill
directories missing a `SKILL.md`, and state directories left behind by deleted
profiles.

`--dry-run` and `-v` work throughout. `list` redacts literal secret values and
flags them, so the output is safe to paste.

Details and the secret-handling rules for `mcp.json`: [profiles/README.md](profiles/README.md).

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
*daemon*, not the CLI. Both services read the same `WORKSPACE_DIR`, which
`oglimmer.sh run` exports from the profile — so there is one value to change and
the two can't diverge:

```bash
./oglimmer.sh new my-project ~/dev/my-project
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
