# yggdrasil

> In Norse mythology, [Yggdrasil](https://en.wikipedia.org/wiki/Yggdrasil) is
> the immense world tree whose branches and roots connect the Nine Worlds and
> hold the cosmos together.

> [!IMPORTANT]
> The canonical repository is hosted on a self-hosted
> [Forgejo](https://forgejo.org/) instance and push-mirrored to GitHub. The
> GitHub copy is read-only — changes pushed there (commits, PRs, edits) will
> **not** be persisted and will be overwritten by the next mirror sync.

GitOps configuration for my Kubernetes infrastructure. A single repository drives
three Kubernetes clusters through [Argo CD](https://argo-cd.readthedocs.io/)
using an app-of-apps / hub-and-spoke topology.

## Topology

Argo CD runs on the **`homelab`** cluster (the hub) and manages all three
Argo-managed clusters as spokes:

| Cluster          | Role                                             |
| ---------------- | ------------------------------------------------ |
| `homelab`        | Hub — hosts Argo CD, Vault, and most workloads   |
| `cloud`          | Spoke — internet-facing / cloud-hosted workloads |
| `home-assistant` | Spoke — Home Assistant and related integrations  |

Each cluster is registered in Argo CD as a cluster secret
(`argocd.argoproj.io/secret-type: cluster`). Clusters run Talos on Proxmox;
networking is Cilium + the Gateway API.

## How it bootstraps

Two `ApplicationSet`s at the repo root use Argo CD's **cluster generator** to
fan out over every registered cluster. For a cluster named `<cluster>` they
template one `Application` per cluster, sourced from `<cluster>/…`:

1. **`namespace-bootstraper.yaml`** (sync-wave `0`) — deploys `<cluster>/namespaces`
   to the spoke itself (`destination.server: {{ server }}`). Namespaces exist
   before anything lands in them.
2. **`application-bootstraper.yaml`** (sync-wave `1`) — deploys `<cluster>/applications`.
   These `Application` objects are created on the **hub** (`destination.name: homelab`),
   which is where Argo CD reconciles them; each individual `Application` then
   targets its own destination cluster.

So the flow is:

```
ApplicationSet (per cluster)
  └─ <cluster>/applications/*.yaml   → Application (Helm chart or in-repo manifests)
       └─ actual workloads on the target cluster
```

## Repository layout

```
<cluster>/                     # one directory per cluster: cloud, home-assistant, homelab
├── applications/              # Argo CD Application definitions (the app-of-apps layer)
│   ├── <name>.cd.yaml         #   the workload — usually a Helm chart with inline valuesObject
│   └── <name>-resources.yaml  #   companion App: directory-recurse over <cluster>/<name>/
├── namespaces/                # Namespace objects, deployed first (sync-wave 0)
├── cluster-scoped/            # cluster-wide resources: RBAC, ClusterSecretStores, policies
└── <name>/                    # supporting manifests for an app (ExternalSecrets,
                               #   ConfigMaps, HTTPRoutes, Postgres clusters, backups, …)
```

### Naming conventions

- **`*.cd.yaml`** — an Argo CD `Application`, typically a Helm release configured
  entirely through `spec.source.helm.valuesObject`.
- **`*-resources.yaml`** — an `Application` that recurses a directory of plain
  manifests (`directory.recurse: true`) providing the app's supporting resources.
- Everything runs under the `k8s-platform` Argo CD `AppProject`.

## Secrets

No secret material is committed. Secrets are synced at runtime by
[External Secrets Operator](https://external-secrets.io/) from HashiCorp Vault
via the `vault-backend-platform` `ClusterSecretStore`. Application manifests
reference the generated Kubernetes secrets by name (`existingSecret…`).

## Dependencies / conventions

- **Renovate** keeps Helm charts, container images, and CI actions current.
  Image tags carry `# renovate:` comments so digests/versions stay pinned and
  auditable. Config extends the shared `renovate/config` preset.
- **CI** (`.forgejo/workflows/pr.yaml`) runs `yamllint` on every PR against
  `main` / `release/**`. Actions are pinned by commit SHA with a default
  `permissions: {}`.
- **pre-commit** enforces yamllint plus trailing-whitespace / EOF / YAML checks
  locally — install with `pre-commit install`.

## Bootstrapping a rebuild

The self-managing loop above assumes a few things already exist on the hub —
these are the manual prerequisites for a from-scratch rebuild:

1. A running Argo CD on the `homelab` cluster.
2. The `k8s-platform` `AppProject` (referenced by every `Application`; **not**
   currently tracked in this repo).
3. Cluster secrets registering `cloud`, `home-assistant`, and `homelab`.
4. A reachable Vault with the platform secrets populated, plus the
   `vault-backend-platform` `ClusterSecretStore`.

Once those are in place, applying `namespace-bootstraper.yaml` and
`application-bootstraper.yaml` lets Argo CD reconcile the rest of the tree.

## License

MIT — see [LICENSE](./LICENSE).
