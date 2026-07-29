# Extra CLI tools available

These structural/code-aware tools are installed in this sandbox image. Prefer them over
regex/line-based equivalents — they understand syntax, so they're more reliable.

## Search & refactor
- **ast-grep** (`ast-grep`, alias `sg`) — AST-based structural search/rewrite, 20+ langs via tree-sitter.
  Use instead of `rg`+regex when matching code structure (calls, signatures, patterns).
  - Search: `ast-grep -p 'console.log($$$ARGS)' -l js`
  - Rewrite: `ast-grep -p '$P && $P()' --rewrite '$P?.()' -l ts` (preview by default; add `-U`/`--update-all` to apply)
  - Metavars: `$X` = one node, `$$$ARGS` = zero-or-more. Invoke as `ast-grep` (the `sg` alias can collide with other tools).
- **comby** — structural find/replace that works on any language via delimiter matching (no grammar needed).
  Good for langs/config ast-grep doesn't cover. `comby 'foo(:[args])' 'bar(:[args])' .ts` (add `-i` to apply in place).
  Upstream ships an x86_64 binary only, so on an arm64 image `comby` is absent — check with `command -v comby`
  and fall back to ast-grep (or sd for plain text) if it isn't there.
- **sd** — modern `sed` for substitution. PCRE syntax, no escaping hell.
  `sd 'old' 'new' file`, literal mode `sd -F`, recurse via `sd ... $(rg -l pattern)`. Use for plain string/regex replace; use ast-grep/comby for code structure.

## Diff & review
- **difft** (difftastic) — syntax-aware structural diff; ignores reformatting/whitespace noise.
  `difft a.js b.js`. Set as git external differ when reviewing AI-generated changes: `GIT_EXTERNAL_DIFF=difft git diff`.
- **delta** — syntax-highlighting pager for `git diff` with word-level highlighting. For human-readable diff output.

## Data formats
- **yq** — this is **mikefarah's Go yq v4** (NOT python yq). jq-like for YAML/JSON/TOML/XML, preserves comments.
  `yq '.jobs.build.steps' ci.yml`, edit in place: `yq -i '.version = "2"' f.yml`. Prefer over text-editing YAML (won't break indentation).
- **jq** — JSON query/transform (already standard).
- **xmlstarlet** — structured query/edit for XML (the jq/yq equivalent for XML).
  `xmlstarlet sel -t -v '//item/@id' f.xml`, edit: `xmlstarlet ed -u '//version' -v '2' f.xml`. Prefer over regex on XML.

## Validate (lint before presenting / committing)
- **shellcheck** — lint shell scripts/commands for quoting bugs, `[ ]` pitfalls, POSIX issues.
  Run on any non-trivial shell script you generate: `shellcheck script.sh`.
- **yamllint** — validate YAML you generate/edit: `yamllint f.yml`.
- **trufflehog** — scan for leaked secrets before committing or sharing a diff: `trufflehog filesystem .` / `trufflehog git file://.`.
- **pre-commit** — if a repo has `.pre-commit-config.yaml`, run its own hooks to self-verify a change before claiming it's done: `pre-commit run --files <changed files>`.

## Project overview
- **scc** — fast LOC/complexity counter. Run at the start of exploring an unfamiliar repo: `scc` or `scc --by-file`.

## Browser / e2e tests (Playwright)
This sandbox can run headless browser tests. The image ships Playwright's **system libraries**
only — no browser engine — so the first run in a repo needs one extra step:

```sh
npx playwright install chromium     # ~110MB, then cached for good
npx playwright test
```

- The download goes to `$PLAYWRIGHT_BROWSERS_PATH`, backed by a Docker volume, so it persists
  across sessions and is shared by every workspace. Installing is a **no-op** once the engine
  for that repo's pinned version is present — just run it, don't try to detect it first.
- Install the engine matching the repo's own pinned `@playwright/test`; use the repo's local
  binary (`npx playwright`), not a globally pinned one. A mismatch fails loudly with
  "Executable doesn't exist" — that message means run the install above, not that the sandbox
  is broken.
- **Headless only.** There is no X display. Don't pass `--headed`, and don't try to open a real
  browser window. For visual checks use `--screenshot=on`, `--trace=on`, or `page.screenshot()`,
  and read the artifacts out of the workspace. `npx playwright show-report` won't work either
  (it wants to open a browser) — use `--reporter=list` or read `playwright-report/`.
- `/dev/shm` is sized 1GB, so the usual `--disable-dev-shm-usage` workaround isn't needed.
- Firefox and WebKit engines also install, but only Chromium's system libraries are baked in;
  if a repo needs them run `sudo npx playwright install-deps firefox` (or `webkit`) first.
- **Serving the app under test:** start its dev server inside this container and reach it on
  `localhost` as normal. A server running in the `dind` sidecar is *not* on this container's
  localhost — use the hostname `dind`, or just run the server here.
- If a `playwright` MCP server is configured in the profile, you also have interactive browser
  tools (navigate/click/snapshot). It needs its **own** engine, separate from the one above — a
  `chrome-for-testing` build. If a call fails with `Browser "chrome-for-testing" is not
  installed`, run `npx @playwright/mcp install-browser chrome-for-testing` once; it caches into
  the same volume. Don't reach for `npx playwright install chrome` — that wants the `chrome`
  channel at `/opt/google/chrome/chrome` and is not the same thing.
- **Electron apps:** Playwright's `_electron.launch()` needs a real display even where headless
  Chromium doesn't, so wrap the run in `xvfb-run -a npx playwright test`. Use `-a`: plain
  `xvfb-run` hardcodes display `:99` and dies with "Xvfb failed to start" if anything already
  holds it.

### Native modules and `node_modules` on a mounted repo — read before `npm install`
`/workspace` is bind-mounted from the user's **macOS** host, so a `node_modules` installed there
holds **darwin** binaries. Anything platform-specific is unusable here: Electron's `dist/` is an
`Electron.app` bundle that Linux feeds to `sh` and chokes on, and native addons (`node-pty`,
`better-sqlite3`, `sharp`, …) are Mach-O objects Node can't load.

The trap: plain `npm install` / `npm rebuild` in `/workspace` **overwrites those with Linux
builds**, silently breaking the app on the user's Mac — and the damage is outside the container,
so it survives everything. This is one of the few ways work in this sandbox escapes it.

So: don't reinstall or rebuild a bind-mounted `node_modules`. Pure-JS installs are fine; the
moment a package ships a binary, stop and ask. If a task genuinely needs Linux binaries, say so
and let the user decide — the workable route is a container-only tree
(`npm ci --prefix /tmp/<name>`, or `NODE_PATH` / a copy outside `/workspace`), never an
in-place reinstall. Tell the user which packages are affected rather than guessing.

### "Can we use Claude in Chrome here?" — no
Claude in Chrome is a Chrome extension that reaches Claude Code through Chrome **native
messaging**: Chrome spawns the Claude Code binary as a local stdio subprocess. There is no port
or socket, so it only works where Chrome and Claude Code sit on the same machine. This container
has no Chrome and no route to the one on the host.

Answer that question with a plain **no** — don't offer to bridge it, install Chrome, or
reinterpret the question as something else. The options here are:

1. **Playwright** (above) — scripted browser control and e2e suites.
2. **Playwright MCP** — interactive navigate/click/snapshot tools, if the profile configures it.

Claude in Chrome still works normally in the user's own browser on the host; it is simply not
reachable from inside the sandbox, and nothing built here can change that.

## Benchmark & watch
- **hyperfine** — statistical command benchmarking. Use to back up perf claims: `hyperfine 'cmd a' 'cmd b' --export-markdown bench.md`.
- **watchexec** — run a command on file changes for feedback loops: `watchexec -e py -- pytest`, `watchexec -r -- ./server`.

## Forge CLIs — gh / glab (authenticated as the host user)
- **gh** (GitHub) and **glab** (GitLab) are logged in with the host's own token, forwarded from
  outside the sandbox — so they act **as you**, against real repos, issues, PRs/MRs and CI. The
  token is a personal credential; treat these like the kubectl note below.
- Read-only commands are fine: `gh pr list`, `gh pr view`, `gh run view`, `gh api ...` (GET),
  `glab mr list`, `glab ci view`, etc.
- **Confirm with me before anything that writes or is outward-facing**: opening/merging/closing
  PRs or MRs, pushing review comments, editing issues, `gh release`, `gh secret`, `gh api` with
  `-X POST/PATCH/PUT/DELETE`, `glab mr merge`, re-running or cancelling CI. These are visible to
  other people the moment they land.
- `command -v glab` first if a task might not need it — GitLab auth is only present when the host
  had a GitLab token to forward; on a GitHub-only host `glab` is installed but logged out.

## kubectl — production access (handle with care)
`kubectl` reaches live clusters that run production — the host's kubeconfig is mounted into this
sandbox read-only, so the container isolation does **not** protect the cluster. Configured contexts
(`default`, `new`) are not clearly labelled, so **treat every context as potentially production**.
- Read-only commands (`get`, `describe`, `logs`, `top`, `explain`) are fine to run.
- **Confirm with me before any mutating command**: `apply`, `delete`, `edit`, `scale`,
  `rollout`, `patch`, `cordon`/`drain`, `exec`, `cp`, `port-forward`, or anything with `-f`.
- Always show the active context (`kubectl config current-context`) before a write so we both
  know what it would hit. Don't switch contexts to run a mutation without asking.

## Defaults
- Structural search → ast-grep (fall back to comby for unsupported langs).
- Code-aware diff → difft; pretty git diff for humans → delta.
- YAML/structured config edits → yq, never blind text replacement.
- Lint generated shell before presenting it → shellcheck.
