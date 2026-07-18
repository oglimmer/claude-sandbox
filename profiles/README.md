# Profiles

One profile per workspace. A profile carries the directory it works on, so
naming the profile is enough to start:

```sh
../oglimmer.sh -p my-api run
```

Everything else is optional — a profile with only a `workspace` file behaves
exactly like the sandbox did before profiles existed.

```
profiles/
  common/
    skills/            skills every profile gets
  <profile>/
    workspace          the host directory to mount at /workspace
    skills/            skills only this workspace gets (copied over common/)
    plugins/           plugin directories, passed via --plugin-dir
    mcp.json           MCP servers, passed via --mcp-config   (gitignored)
    settings.json      settings overlaid on ../../claude-settings.json
```

## How each piece is wired

| Piece | Mechanism |
| ----- | --------- |
| `workspace` | Read by `oglimmer.sh run`, exported as `WORKSPACE_DIR`, bind-mounted at `/workspace` by both the `claude` and `dind` services |
| `skills/` | Copied into `~/.claude/skills` at startup — `common/` first, then the profile on top, so a profile can shadow a common skill by name |
| `plugins/` | `--plugin-dir`, which loads plugin directories without a marketplace install |
| `mcp.json` | `--mcp-config` |
| `settings.json` | `--settings`, layered on the repo-wide `claude-settings.json` |

Skills are rebuilt from the read-only mounts on every start, so switching
profiles never leaves another workspace's skills behind, and host-side edits
land on the next run.

## Secrets in mcp.json

`profiles/*/mcp.json` is gitignored, because MCP definitions routinely carry
tokens. Prefer keeping the secret in `.env` and referencing it as `${VAR}` —
Claude Code expands environment variables in this file. The variable also needs
a passthrough in `docker-compose.yml`'s `environment:` block to reach the
container. See `default/mcp.json.example`.

Think about blast radius before adding a server: whatever it can reach, the
agent can reach. A production Grafana or an email account is a much larger grant
than the workspace bind mount itself.

## The workspace belongs to the profile

`profiles/<name>/workspace` holds one path — the repo this profile works on.
`./oglimmer.sh new` writes it, `run` exports it as `WORKSPACE_DIR`, and both
compose services mount it at `/workspace`. Relative paths starting with `./`
are resolved against this repo, like compose does; everything else is stored
absolute.

Keeping it here rather than in `.env` means there is one source of truth. The
alternative — profile in one file, path in another — fails quietly: you get
`my-api`'s skills, MCP servers and session history pointed at a different repo,
with nothing to indicate it.

Precedence, highest first:

```
-w DIR  >  WORKSPACE_DIR in the environment  >  profiles/<name>/workspace  >  .env
```

Use `-w` for a one-off (`../oglimmer.sh -p my-api -w ~/dev/other run`). A
profile with no `workspace` file still works — it falls through to `.env` —
but `doctor` flags it, because which repo it mounts then depends on whatever
was edited there last.

### Changing it later

```sh
../oglimmer.sh workspace my-api                  # where does it point?
../oglimmer.sh workspace my-api ~/dev/my-api-v2  # repoint it
```

This runs the same checks `new` does — the directory must exist, and it warns
if another profile already owns it.

It also warns when the profile has session transcripts recorded, because those
stay behind: they live in `profile-state/<name>/projects/-workspace/`, keyed by
the mount point rather than the repo, so after repointing, `run -c` resumes a
conversation about the *old* directory. Repointing is the right move when a
project moved on disk. When it's a genuinely different project, make a second
profile instead — that is what keeps the histories apart.

## Sessions are per profile

The `~/.claude` volume is named per profile (`claude-config-<profile>`), so
history and logins are isolated. This is also what makes `CLAUDE_ARGS=-c` behave
sensibly: every workspace mounts at `/workspace`, so with a single shared volume
Claude Code would treat unrelated repos as the same project and `-c` would
resume the wrong session.

A new profile starts logged out — run `/login` once inside it.

## Adding a profile

```sh
../oglimmer.sh new my-api ~/dev/my-api
```

The directory is mandatory — it is what makes the rest of the profile mean
anything. Run it with `../oglimmer.sh -p my-api run`, or set
`CLAUDE_PROFILE=my-api` in `.env` to make it the default.

`new` also creates `profile-state/my-api`, which
matters: compose creates a missing bind-mount source as **root**, and a
root-owned directory is the usual cause of a profile that silently contributes
nothing. `../oglimmer.sh doctor` finds that case and the other common ones.

Skills are copied with `cp -aL`. Skills under `~/.claude/skills` are frequently
symlinks into a checkout elsewhere, and copying the link instead of its target
would leave a pointer that resolves on the host and dangles in the container.
