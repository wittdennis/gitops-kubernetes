# Issue tracker: Forgejo (`tea` CLI)

Issues and PRDs for this repo live in the repo's **Forgejo** issue tracker at
`git.derwitt.site/homelab/yggdrasil`. The GitHub copy is a read-only mirror —
never treat GitHub Issues/PRs as a source of truth.

Drive all operations with the [`tea`](https://gitea.com/gitea/tea) CLI (the
Gitea/Forgejo-compatible client). Commands below are pinned to **`tea` 0.15.0**.
`tea` infers the login/repo from the local remote; add `--repo homelab/yggdrasil`
if it can't.

## Setup (once)

- `tea login add --name derwitt --url https://git.derwitt.site --token <token>`
  (token from Forgejo → Settings → Applications).
- Verify with `tea login list` and `tea issues ls`.

## Conventions

- **Create an issue**: `tea issues create --title "..." --description "..."`.
  The body flag is `--description` / `-d` (not `--body`). Use `$(cat file.md)`
  or a shell heredoc for multi-line bodies. Optional: `--labels/-L`,
  `--assignees/-a`, `--milestone/-m`.
- **Read an issue**: `tea issues <index> --comments`. For just the thread,
  `tea comments list <index>`.
- **List issues**: `tea issues ls --state open --output json` with `--labels/-L`,
  `--state (all|open|closed)`, `--kind (issues|pulls|all)`, and `--fields/-f`
  filters. JSON output keeps parsing stable.
- **Comment on an issue**: `tea comments add <index> "..."` (the shorthand
  `tea comment <index> "..."` still works; body can also be passed as `-d`).
- **Apply / remove labels**: `tea issues edit <index> --add-labels "..."` /
  `--remove-labels "..."`. Labels must already exist
  (`tea labels ls` / `tea labels create`).
- **Close**: `tea issues close <index>` — dedicated subcommand, no `--state`
  flag. Leave a closing `tea comments add` first where the reason isn't obvious.
- **Reopen**: `tea issues reopen <index>`.

## Pull requests as a triage surface

**PRs as a request surface: no.** _(Set to `yes` if this repo treats external
PRs as feature requests. Solo GitOps repo — off by default.)_

When set to `yes`, PRs run through the same labels and states as issues; reach
them with `tea pulls ls` / `tea pulls <index>` (or `tea issues ls --kind pulls`).

## When a skill says "publish to the issue tracker"

Create a Forgejo issue with `tea issues create`.

## When a skill says "fetch the relevant ticket"

Run `tea issues <index> --comments`.
