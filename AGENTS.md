# yggdrasil

GitOps configuration driving three Kubernetes clusters (`homelab`, `cloud`,
`home-assistant`) via Argo CD. See `README.md` for topology.

## Conventions

### Manifest layout

**One YAML resource per file.** Do not put multiple Kubernetes resources in a
single manifest (no multi-document `---` files). Give each file the name of the
resource it holds (e.g. `gateway-api/litellm.yaml`, not a combined
`httproute.yaml` with several routes).

### Pod Security

New namespaces are `pod-security.kubernetes.io/enforce: restricted` — **always**.
Do not hedge to `baseline`/`privileged` out of uncertainty. Only relax below
`restricted` if, during testing, it is actually found that `restricted` cannot
work — UNLESS it is 100% certain beforehand that greater privileges are needed.

## Agent skills

### Issue tracker

Issues live in the repo's Forgejo tracker at `git.derwitt.site/homelab/yggdrasil`,
driven via the `tea` CLI. The GitHub mirror is read-only. See `docs/agents/issue-tracker.md`.

### Domain docs

Single-context — one `CONTEXT.md` + `docs/adr/` at the repo root. See `docs/agents/domain.md`.
