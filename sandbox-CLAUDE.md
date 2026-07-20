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
