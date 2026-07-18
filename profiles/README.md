# Profiles

One profile per workspace. `CLAUDE_PROFILE` in `.env` selects which one is
mounted, alongside the `WORKSPACE_DIR` it belongs to:

```sh
WORKSPACE_DIR=~/dev/my-api
CLAUDE_PROFILE=my-api
```

Everything is optional — a profile with nothing in it behaves exactly like the
sandbox did before profiles existed.

```
profiles/
  common/
    skills/            skills every profile gets
  <profile>/
    skills/            skills only this workspace gets (copied over common/)
    plugins/           plugin directories, passed via --plugin-dir
    mcp.json           MCP servers, passed via --mcp-config   (gitignored)
    settings.json      settings overlaid on ../../claude-settings.json
```

## How each piece is wired

| Piece | Mechanism |
| ----- | --------- |
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

## Sessions are per profile

The `~/.claude` volume is named per profile (`claude-config-<profile>`), so
history and logins are isolated. This is also what makes `CLAUDE_ARGS=-c` behave
sensibly: every workspace mounts at `/workspace`, so with a single shared volume
Claude Code would treat unrelated repos as the same project and `-c` would
resume the wrong session.

A new profile starts logged out — run `/login` once inside it.

## Adding a profile

```sh
../oglimmer.sh new my-api
```

Then point `.env` at it. `new` also creates `profile-state/my-api`, which
matters: compose creates a missing bind-mount source as **root**, and a
root-owned directory is the usual cause of a profile that silently contributes
nothing. `../oglimmer.sh doctor` finds that case and the other common ones.

Skills are copied with `cp -aL`. Skills under `~/.claude/skills` are frequently
symlinks into a checkout elsewhere, and copying the link instead of its target
would leave a pointer that resolves on the host and dangles in the container.
