# ADR-0003: Opportunistic 7900 XTX inference tier

- **Status:** Accepted
- **Date:** 2026-08-04 · **Revised:** 2026-08-13
- **Cluster:** `otter` — a new, deliberately **isolated** single-node cluster
- **GitOps:** Flux, from its own repo `homelab/jotunheim` — not this one
- **Extends:** ADR-0001 (LiteLLM as the pluggable seam) · epic #916

> **Revision 2026-08-11.** Originally decided: an **in-cluster Argo CD** pulling an
> `otter/` tree from this repo, with host config in `ansible-playbooks`. Now:
> **Flux**, and **one self-contained repo — `homelab/jotunheim` — holding both the
> manifests and the Ansible** for the machine. Everything else — role, isolation,
> preemption, fallback chain, secrets — is unchanged.

> **Revision 2026-08-12.** The **read-only deploy key is dropped**: `homelab/jotunheim`
> is a public repo on a LAN-only Forgejo, so Flux clones it anonymously over HTTPS and
> `otter` now holds **no git credential at all** — strictly less than the deploy key it
> replaces, since it protected read access that was already anonymous. The trust
> boundary tightens accordingly: full compromise of the box yields one Vault path and
> nothing else. Consequence: nothing secret may ever be committed to `jotunheim`.

> **Amendment 2026-08-12.** `mogenius-operator` is deployed on `otter` as an
> infrastructure component, so the box is visible on the mogenius platform like the
> estate's other three clusters. This is a **deliberate, named hole in the trust
> boundary above**: it adds a second credential (its API key) and maintains outbound
> websockets to `mogenius.com` over which the platform can drive the cluster. The
> boundary is otherwise unchanged, and this is not precedent for further exceptions.

## Context

ADR-0001 accepted a hard ceiling: a single **Arc B580** with 12 GB VRAM holds
about one 7B–14B model at Q4, making local coding assistance "adequate, not
frontier" and leaving cloud aliases to cover anything harder.

A **gaming workstation** already exists — **otter**: CachyOS, 64 GB RAM, Radeon
**7900 XTX** (24 GB) — and idles most of the day. Serving inference from it while
it is idle lifts the ceiling substantially:

| | B580 (tier-1) | 7900 XTX (tier-2) |
|---|---|---|
| VRAM | 12 GB | 24 GB |
| Memory bandwidth | ~456 GB/s | ~960 GB/s |
| Stack | Vulkan (spiked in #885) | ROCm, `gfx1100` first-class |
| Throughput | 34.6 tok/s (llama3.1:8b, measured) | ~2x at equal model (expected) |
| Fits | one 7–8B at a time | 30B-class MoE or 32B dense Q4 |

It is **opportunistic (spot) capacity**: intermittently available, preempted by a
higher-priority workload, and less trusted than a cluster node. Those three
properties, not isolation from the network, are what the design has to absorb.

The governing constraint: **gaming is the primary workload and always wins.**
Inference is the scavenger.

## Decisions

| Area | Decision | Rationale |
|---|---|---|
| Role | **Second tier behind LiteLLM**; the B580 stays tier-1 and always-on | Cold start is 60–120 s (power on + boot + model load). HA Assist, Paperless and embeddings cannot absorb that, so they must never depend on tier-2. |
| Cluster membership | **Its own isolated single-node k3s cluster**, reconciled by an **in-cluster Flux** from its **own repo** (`homelab/jotunheim`). Not a node of `homelab`, not a hub-managed spoke, not a tree in this repo | Keeps a GitOps workflow for the workloads while containing the blast radius. Joining `homelab` would put a flapping node and hub credentials on a machine that runs games and mods; a hub-managed spoke would leave hub Argo CD staring at an unreachable cluster ~20 h/day. An in-cluster reconciler is asleep exactly when the box is, so nobody is watching and nothing alerts. |
| GitOps engine | **Flux** on `otter`, not the estate's Argo CD | A single-node, single-tenant cluster uses none of what Argo CD is good at — cluster generators, RBAC'd UI, SSO — and each of those is another component to secure, or to run headless, on the least-trusted machine in the estate. Flux is a handful of pull-only controllers with no API server, no UI and no dex, and the whole install is `flux install` plus two objects Ansible can apply. Cost: a second GitOps tool in the estate (risk 6). |
| Cluster name | **`otter`** — the machine's own name, not a role name like `gaming` | Single-node cluster: cluster and machine are the same thing, so naming it after the host is precise rather than leaky. Diverges from the role-named `homelab`/`cloud`/`home-assistant` deliberately. |
| Hub isolation | Deliberately **no cluster secret on the hub** for `otter`, and **nothing describing `otter` in this repo** | The root `ApplicationSet`s generate from registered cluster secrets, so nothing here can target `otter` — and with the manifests in another repo there is nothing here to target either. Isolation is a property of the bootstrap, not a rule to remember. |
| Repo layout | A **separate repo, `homelab/jotunheim`**, holding **both** the manifest tree (Flux-shaped: `clusters/otter/`, `infrastructure/`, `apps/`) **and** `ansible/` for the host — not a top-level `otter/` here, and not a role in `ansible-playbooks` | This repo's conventions are Argo-shaped: `applications/` holds `Application` objects, generated over registered clusters. A Flux tree living here would follow none of them while looking like it should, and would be read by no `ApplicationSet` — dead code by inspection. Keeping the Ansible with it makes `otter` **self-contained**: one repo is the complete description of one machine, rebuildable without reaching into the estate's general-purpose repos, and the repo boundary is the trust boundary — `jotunheim` describes one cluster and holds no secret material, so it can be public and `otter` needs no credential to read it. Cost: Renovate, lint and agent conventions set up a second time (risk 6). |
| Bootstrap | `flux install` (source-, kustomize- and helm-controller only), plus a `GitRepository` + root `Kustomization` for `jotunheim` **applied by Ansible**, its path scoped to the manifest subtree. Explicitly **not** `flux bootstrap` | `flux bootstrap` commits the install manifests back into the repo and so needs a write credential, which contradicts the read-only trust boundary below. Applying the two sync objects declaratively keeps the credential read-only and keeps day-0 in Ansible with the rest of the host config. Scoping the path matters now that `ansible/` shares the repo: `kustomize-controller` must never walk it. Trimming the controllers drops notification and image-automation, neither of which has a job here. |
| Inference engine | **Ollama, ROCm build**, via the same otwld chart used for the B580 | `gpu: {enabled: true, type: amd}` — the chart's own GPU helper covers AMD, which is exactly the branch the B580 values file has to work around. |
| GPU exposure | **AMD device plugin** → `amd.com/gpu`, mirroring the Intel plugin on `homelab` | Keeps workload pods `restricted`; only the plugin DaemonSet is privileged, same shape as `intel-device-plugins`. |
| Endpoint auth | **Bearer-token reverse proxy in-cluster** in front of the Ollama Service; Ollama never listens on the LAN itself | Ollama has no auth of its own, and AGENTS.md does not permit relaxing security for `ai-platform`. Being in-cluster, the proxy is GitOps-managed like everything else rather than hand-rolled host config. |
| Secrets | **ESO on `otter`** against Vault, with a **read-only Vault token scoped to just this cluster's credentials**; the token Secret itself is Ansible-bootstrapped | Keeps the repo's Vault convention intact on the new cluster. Vault is already reachable at `vault.derwitt.site` through the hub gateway, so `otter`'s `ClusterSecretStore` needs no `caProvider` (unlike the hub's in-cluster store, which mounts the Vault CA). |
| Trust boundary | Outbound-only from `otter`, and exactly **one credential**: a **read-only path-scoped Vault token**. `homelab/jotunheim` is public, so Flux clones it anonymously over HTTPS — **no git credential on the box at all**. No credential for this repo, nothing inbound to the hub's control planes; no kubeconfig, no service account, no write credential. **One named exception:** `mogenius-operator` (see below) | The box runs games and mods, so it is the least trusted machine in the estate. Its full compromise yields one Vault path — not cluster access, not `yggdrasil`, and not even a repo credential. A deploy key would have protected read access that is already anonymous, while adding a stealable secret to the least-trusted machine. The price is that `jotunheim` can never hold secret material, which was already true of it. |
| Platform visibility | **`mogenius-operator` runs on `otter`**, with a single-instance valkey and its API key from Vault. Accepted as the **only** hole in the trust boundary above | The estate's other three clusters all run it, and a tier that is invisible is a tier nobody notices has been down for a week. The cost is real and stated rather than hidden: a second credential on the least-trusted box, and outbound websockets to `mogenius.com` over which the platform can drive this cluster. It is tolerable *here* specifically because `otter` holds nothing — no hub credential, no repo credential, no data — so the blast radius of that control is one disposable cluster. Nothing about it extends to the hub, and it is not precedent for a second exception. |
| Network exposure | The proxied endpoint reachable on the LAN only, `nftables` allow-list of the cluster's egress addresses | Least reachable surface that still works; no WAN exposure, no external-dns record. |
| Gaming preemption | The `gamemode` hook **stops k3s wholesale** — it must not scale the workload down | `kustomize-controller` reverts a `replicas: 0` on its next pass, while `helm-controller`'s drift detection is opt-in — so scale-to-zero is either fought or tolerated depending on how the object happens to be managed. Neither is a mechanism to build on. Stopping k3s also removes containerd and the Flux controllers while gaming, and yields connection-refused, which LiteLLM already handles via cooldown. |
| VRAM release | `OLLAMA_KEEP_ALIVE` of **1h** in addition to the hook | Covers idle-but-not-gaming: weights leave VRAM without stopping the cluster. Originally short, on the assumption the timer was part of getting out of a game's way. It is not: the hook stops the cluster outright, and once that was proven the timer's only remaining job is a genuinely idle stretch. An hour keeps a model resident across a working day instead of charging an 18 GB reload for every pause longer than the timeout. |
| Unavailability | LiteLLM **fast-fail per deployment** (short timeout, `allowed_fails`, `cooldown_time`) plus an explicit **fallback chain** | An offline backend must fall back within a second, not hang the caller. This is where ADR-0001's LiteLLM seam pays off. |
| Fallback chain | XTX 30B-class → B580 `qwen2.5-coder:7b`, and **stops there**. No fallback reaches a cloud model | Degrades along quality, not availability: the request completes on the always-on card when the workstation is off. Originally this chain ended at a cloud alias. Removed: those are metered, and a machine being switched off at home is not a reason to start spending money. Reaching a paid model stays something the caller does by selecting it. The chain is a convenience rather than a dependency: nothing unattended routes to tier-2 at all. Automated consumers name a tier-1 model explicitly, and a tier-2 model is selected by a person who knows whether the machine is switched on. So a failed fallback inconveniences that person; it does not break a scheduled job. |
| Embeddings | **Tier-1 only.** Never served by the XTX tier, never given a fallback | Vectors from different models are not comparable, so a fallback would silently return *meaningless* retrieval rather than degraded retrieval — the failure has no error and looks like a bad answer. Embeddings are also needed at query time, not just ingestion, so a tier-2 embedding route would break RAG whenever the box sleeps. `nomic-embed-text` is ~275 MB and costs the B580 almost nothing. |
| Health checking | Hub-side background health checks off or on a long interval | A backend down ~20 h/day would otherwise generate constant probe traffic and log noise. |
| Wake | **Powered on by hand, and fully off in between.** No Wake-on-LAN, no idle auto-suspend, no request-triggered wake | The machine is WiFi-only, so there is no wired NIC to wake. Its card advertises WoWLAN magic-packet support and it does not work in practice; and it would not help anyway, because the machine is powered off rather than suspended, leaving the card unpowered. Availability therefore becomes a deliberate act: the tier is up when it has been switched on. Nothing downstream changes, since LiteLLM already fast-fails and falls back, which is what "spot capacity" meant. Revisit only if the machine gains wired Ethernet. |
| Config ownership | **Day-0 in Ansible** (k3s install, `flux install`, the `GitRepository` + root `Kustomization`, Vault token Secret, firewall rules, gamemode hook); **day-2 in Flux**. Both halves live in `jotunheim` — the Ansible does **not** go in `ansible-playbooks` | The tool split is the estate's usual one (Ansible owns the host, the GitOps controller owns workloads); the repo split is not. Putting one machine's host config in the estate's shared playbook repo would scatter `otter` across three repos to gain nothing — it shares no hardware, no OS and no lifecycle with the Talos nodes there. Keeping it in `jotunheim` means the box is rebuildable from one clone, and nothing about `otter` lands in `yggdrasil` except the LiteLLM entry. Cost: no shared roles, so genuinely common bits (`node_exporter`) get copied rather than reused. |
| Observability | `node_exporter` + `amd_smi` locally; tier availability read from the already-scraped LiteLLM fallback-rate metrics on the hub | "Was it there when I needed it" is a question about the *seam*, which LiteLLM answers. Scraping or remote-writing from a box that is off ~20 h/day would produce mostly-gap series for little gain. |
| Model set | Distinct model names for the 24 GB tier — not aliases shadowing tier-1 names | Which tier answered stays visible in the picker and in metrics; no silent quality swings. |

## Alternatives considered

- **k3s agent joining `homelab`.** Rejected: Talos runs its own PKI and node
  lifecycle, and a node that vanishes at every game launch means permanent
  `NotReady` churn plus hub credentials on the workstation.
- **Hub-managed spoke** (cluster secret + hub Argo CD). Rejected: it moves the
  flapping from kubelet to Argo CD — apps permanently `Unknown`, sync retries
  failing all day — and requires an admin kubeconfig for the box on the hub.
- **In-cluster Argo CD pulling an `otter/` tree from this repo** — the original
  decision here, superseded 2026-08-11. Rejected on reflection: it put an
  Argo-invisible tree in an Argo-shaped repo, and ran a control plane component
  built for many clusters and many humans on a box with one of each.
- **Flux, but still reading `yggdrasil`.** Rejected: it keeps the dead-code tree
  and hands the least-trusted machine a credential for the repo that describes
  the whole estate, for no benefit beyond one less repo to scaffold.
- **Host config in `ansible-playbooks`, manifests in `jotunheim`.** Rejected: it
  splits one machine across two repos on a tooling boundary that nobody reading
  "how is `otter` built" cares about. The `pci_passthrough` role stays where it is
  — it belongs to `gorilla`, a Proxmox host in the estate proper — but `otter`
  shares nothing with those hosts.
- **Bare Ollama or a Podman Quadlet unit, all config in Ansible.** Viable and
  lighter, and no longer costs a second repo now that host config and manifests
  are co-located anyway. Rejected because Ansible-owned workloads drop Renovate
  coverage of charts/images and the manifest review flow. Remains the fallback if
  k3s upkeep on a rolling-release desktop proves too noisy — and with everything
  in `jotunheim`, that retreat is now a change to one repo.
- **Ansible-bootstrapped Secret instead of ESO on `otter`.** Would have avoided
  any Vault reachability from the box, but at the cost of the repo's
  secrets-from-Vault convention and a token living in two places. A path-scoped
  read-only Vault token is the narrower trade.

## Scope

**In `yggdrasil`:** LiteLLM `model_list` + fallback chain + fast-fail tuning on
`homelab` · README topology update (a fourth cluster that is explicitly *not* a
spoke and *not* described here) · this ADR. Nothing else.

**In `homelab/jotunheim`** (new repo) — everything else, both halves:

- *Manifests:* namespaces, ESO + `ClusterSecretStore`, `mogenius-operator`
  (+ single-instance valkey), AMD device plugin, Ollama (ROCm, model PVC),
  bearer-token proxy + LAN exposure.
- *`ansible/`:* k3s install and upgrades · `flux install` + the
  `GitRepository`/root `Kustomization` · Vault token Secret ·
  firewall allow-list · `gamemode` preempt hook ·
  `node_exporter`.
- *Scaffolding:* its own Renovate config (charts, images **and** Galaxy content),
  lint gate including `ansible-lint`, and agent conventions.

**Out (`ansible-playbooks`):** nothing. `otter` is deliberately absent from the
estate's shared playbook repo.

**Out (Vault):** the path-scoped read-only policy and token for `otter`, plus the
secrets it reads — `mogenius-operator/api-key` and
`mogenius-operator/valkey/credentials`.

**Out (mogenius platform):** `otter` registered as a cluster, and the API key it
issues.

## Open risks (verify at build time)

1. **VRAM release under gaming** — *resolved, with one case accepted rather than
   tested.* Both unload paths work: an explicit unload returned VRAM to 838 MiB
   against an 896 MiB desktop baseline
   (#914), and `OLLAMA_KEEP_ALIVE` expiring on its own has since been confirmed to
   unload as well, which is the path that matters for the idle-but-not-gaming case.
   The `gamemode` hook has since been confirmed in both directions: it stops the
   cluster and frees the card when a game starts, and starts it again when the game
   exits, with Flux reconciling the workloads back on its own. The preemption
   mechanism holds end to end.

   A game launched *during* generation is **not** tested, and deliberately will not
   be: with one person as both the only consumer of the platform and the only user
   of the machine, the two never happen at once without that person knowing. The
   scenario the risk describes does not arise here. Should the tier ever gain a
   second consumer, or the machine a second user, this stops being true and the
   question returns.
2. **24 GB model choice** — *resolved (#914).* Pinned `qwen3-coder:30b`:
   134 tok/s, fully on the GPU at 21.7 GB. `devstral:24b` (24B dense) reached
   46 tok/s and is the recorded fallback, with 4.2 GB free rather than 2.4 GB, if
   context turns out to bind before throughput does. **`qwen2.5-coder:32b` does
   not fit**: it saturated VRAM at 24453 MiB of 24576, left 16% of its layers on
   the CPU and fell to 13 tok/s, below the B580 running a 7B. It degrades
   silently rather than failing.

   The ~2x expectation was beaten roughly fourfold, but the reasoning in the table
   above was wrong about why. Bandwidth is not the mechanism: an A3B MoE activates
   about 3B parameters per token, so it moves far less memory per token than its
   30B size implies. The 24B *dense* model, the honest test of the bandwidth
   argument, managed 1.3x.

   Usable context measured after: **32k fits entirely on the GPU at full speed**
   (21.7 GB, 134 tok/s), and throughput is flat all the way down, so a smaller
   context buys nothing. 64k costs a 4% spill and 15% of throughput, 128k costs
   64%. `OLLAMA_CONTEXT_LENGTH` is now pinned to 32768: left unset it is chosen
   from free VRAM at load time, so the context would have shrunk silently on a day
   the desktop held more. Note the MoE beats a 27B dense model at *every* context
   length including where it spills (114 vs 36 tok/s at 64k), so a dense model
   earns its place on capability, not on context headroom.
3. **k3s on a rolling-release desktop.** CachyOS kernel/containerd churn will
   occasionally break the cluster, and k3s's iptables/nft chains interact with
   the host firewall lockdown. If this becomes routine maintenance, fall back to
   the Quadlet alternative above.
4. **Vault reachability is now a dependency of `otter` starting cleanly.** If the
   hub gateway or Vault is down, ESO cannot populate the endpoint token and the
   tier stays down. Acceptable — tier-2 is best-effort by construction — but it
   means `otter` is not truly standalone.
5. **Power economics invert if the box ends up always-on** — *resolved.* It is
   powered off between sessions rather than suspended, which is the best case for
   this concern rather than the feared one. The trade only needs revisiting if the
   machine starts being left on.
6. **A second GitOps tool and a third repo.** Flux plus `jotunheim` means
   duplicated scaffolding (Renovate for charts/images *and* Galaxy content, lint
   including `ansible-lint`, agent conventions) and two mental models to keep
   current. Seeing far less traffic than `yggdrasil` or `ansible-playbooks`, it is
   the repo that will rot; self-containment also means common Ansible bits are
   copied, so a fix there does not propagate. Watch for it drifting behind on
   chart versions or conventions; if it does, folding the tier back into
   Ansible-owned host config — now a single-repo change — is the honest retreat.

## Consequences

- The local coding tier gets materially better, narrowing ADR-0001's "coding
  quality is bimodal" gap; the cloud alias becomes a rarer escape hatch.
- That improvement is explicitly **best-effort** — tier-2 exists only while the
  workstation is up. The fallback chain makes the degradation graceful, not
  invisible.
- A fourth cluster — the first that is **not** a hub-managed spoke, the first not
  on Argo CD, and the first not described by this repo at all. `yggdrasil`
  mentions it only in the README topology table, in the LiteLLM backend list, and
  here; anyone tracing the tier from this repo has to follow that pointer.
- `otter` is the first machine in the estate whose host config lives outside
  `ansible-playbooks`. That repo is no longer "every host"; the README topology
  note and this ADR are the only breadcrumbs, and the payoff is that one clone of
  `jotunheim` rebuilds the box end to end.
- `otter` holds two credentials, both read-only and narrowly scoped
  (`homelab/jotunheim`, one Vault path). The estate's secret handling stays
  uniform: Vault remains the single source of truth, including for LiteLLM's copy
  of the endpoint token.
- Real GPU telemetry, unlike ADR-0002's passed-through B580 (no MEI/GSC, no power
  limits): bare metal means working `amd_smi` and thermal/power data.
- Adding further backends later costs one `model_list` entry — the seam is now
  exercised by two dissimilar backends rather than assumed.
