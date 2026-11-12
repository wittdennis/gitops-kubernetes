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

### AI platform workloads (`ai-platform`)

The AI/ML workloads deliberately deviate from the standards elsewhere in this
repo and are run in a **true homelab fashion**: availability and redundancy
are intentionally lax — single-replica databases, single-node pinning (the
GPU/AI node), no cross-node HA/failover — because this is a personal platform,
not production. Prefer the simple, resource-frugal option over the resilient one
here.

**Security is the exception and is NEVER relaxed.** `restricted` pod-security,
non-root, dropped capabilities, secrets sourced from Vault via external-secrets,
and SSO in front of human UIs all remain non-negotiable for these workloads,
exactly as everywhere else.

### ServiceAccount token validation

ServiceAccount tokens on `homelab` and `cloud` carry a public issuer on Azure
blob storage (`https://pseud0r4ndomoidc.blob.core.windows.net/oidc/<cluster>`),
published so Entra ID can verify them for workload identity federation.
Components that validate these tokens verify them against the API server: via
TokenReview, or via its own `https://kubernetes.default.svc/openid/v1/jwks`.
That keeps every cluster working while Azure is unreachable. Vault's
cross-cluster JWT mounts pin the signing keys in Terraform for the same reason.

## Agent skills

### Issue tracker

Issues live in the repo's Forgejo tracker at `git.derwitt.site/homelab/yggdrasil`,
driven via the `tea` CLI. The GitHub mirror is read-only. See `docs/agents/issue-tracker.md`.

### Domain docs

Single-context — one `CONTEXT.md` + `docs/adr/` at the repo root. See `docs/agents/domain.md`.
