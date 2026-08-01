# yggdrasil

GitOps configuration driving three Kubernetes clusters (`homelab`, `cloud`,
`home-assistant`) via Argo CD. See `README.md` for topology.

## Agent skills

### Issue tracker

Issues live in the repo's Forgejo tracker at `git.derwitt.site/homelab/yggdrasil`,
driven via the `tea` CLI. The GitHub mirror is read-only. See `docs/agents/issue-tracker.md`.

### Domain docs

Single-context — one `CONTEXT.md` + `docs/adr/` at the repo root. See `docs/agents/domain.md`.
