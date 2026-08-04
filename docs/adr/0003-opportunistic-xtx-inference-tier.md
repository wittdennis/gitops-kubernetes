# ADR-0003: Opportunistic 7900 XTX inference tier

- **Status:** Accepted
- **Date:** 2026-08-04
- **Cluster:** `otter` — a new, deliberately **isolated** single-node cluster
- **Extends:** ADR-0001 (LiteLLM as the pluggable seam) · epic #916

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
| Role | **Second tier behind LiteLLM**; the B580 stays tier-1 and always-on | Cold start is 60–120 s (wake + boot + model load). HA Assist, Paperless and embeddings cannot absorb that, so they must never depend on tier-2. |
| Cluster membership | **Its own isolated single-node k3s cluster** with an **in-cluster Argo CD** pulling this repo directly. Not a node of `homelab`, not a hub-managed spoke | Keeps the estate's GitOps workflow for the workloads while containing the blast radius. Joining `homelab` would put a flapping node and hub credentials on a machine that runs games and mods; a hub-managed spoke would leave hub Argo CD staring at an unreachable cluster ~20 h/day. In-cluster Argo CD is asleep exactly when the box is, so nobody is watching and nothing alerts. |
| Cluster name | **`otter`** — the machine's own name, not a role name like `gaming` | Single-node cluster: cluster and machine are the same thing, so naming it after the host is precise rather than leaky. Diverges from the role-named `homelab`/`cloud`/`home-assistant` deliberately. |
| Hub isolation | Deliberately **no cluster secret on the hub** for `otter` | The root `ApplicationSet`s generate from registered cluster secrets, so `otter/` is structurally invisible to hub Argo CD — the isolation is a property of the bootstrap, not a rule to remember. |
| Repo layout | Top-level `otter/` following the existing per-cluster convention (`applications/`, `namespaces/`, `cluster-scoped/`, `<app>/`) | Same shapes, same Renovate coverage, same review flow. Only the bootstrap differs. |
| Bootstrap | A **root app-of-apps in-cluster**, not the hub's cluster-generator `ApplicationSet`s; `Application` objects live on `otter` with in-cluster destinations | One cluster means the generator buys nothing. Note this inverts the repo's usual "Applications are created on the hub" rule. |
| Inference engine | **Ollama, ROCm build**, via the same otwld chart used for the B580 | `gpu: {enabled: true, type: amd}` — the chart's own GPU helper covers AMD, which is exactly the branch the B580 values file has to work around. |
| GPU exposure | **AMD device plugin** → `amd.com/gpu`, mirroring the Intel plugin on `homelab` | Keeps workload pods `restricted`; only the plugin DaemonSet is privileged, same shape as `intel-device-plugins`. |
| Endpoint auth | **Bearer-token reverse proxy in-cluster** in front of the Ollama Service; Ollama never listens on the LAN itself | Ollama has no auth of its own, and AGENTS.md does not permit relaxing security for `ai-platform`. Being in-cluster, the proxy is GitOps-managed like everything else rather than hand-rolled host config. |
| Secrets | **ESO on `otter`** against Vault, with a **read-only Vault token scoped to just this cluster's credentials**; the token Secret itself is Ansible-bootstrapped | Keeps the repo's Vault convention intact on the new cluster. Vault is already reachable at `vault.derwitt.site` through the hub gateway, so `otter`'s `ClusterSecretStore` needs no `caProvider` (unlike the hub's in-cluster store, which mounts the Vault CA). |
| Trust boundary | Outbound-only from `otter`: **read-only deploy token** for this repo, **read-only path-scoped Vault token**. Nothing inbound from `otter` to the hub's control planes; no kubeconfig, no service account, no write credential | The box runs games and mods, so it is the least trusted machine in the estate. Its full compromise yields read of a repo with no secret material plus one Vault path — not cluster access. |
| Network exposure | The proxied endpoint reachable on the LAN only, `nftables` allow-list of the cluster's egress addresses | Least reachable surface that still works; no WAN exposure, no external-dns record. |
| Gaming preemption | The `gamemode` hook **stops k3s wholesale** — it must not scale the workload down | Auto-sync would revert a `replicas: 0` within seconds, so scale-to-zero and GitOps actively fight each other. Stopping k3s also removes containerd/Argo CD overhead while gaming, and yields connection-refused, which LiteLLM already handles via cooldown. |
| VRAM release | Short `OLLAMA_KEEP_ALIVE` in addition to the hook | Covers idle-but-not-gaming: weights leave VRAM without stopping the cluster. |
| Unavailability | LiteLLM **fast-fail per deployment** (short timeout, `allowed_fails`, `cooldown_time`) plus an explicit **fallback chain** | An offline backend must fall back within a second, not hang the caller. This is where ADR-0001's LiteLLM seam pays off. |
| Fallback chain | `coding-local` → XTX 30B-class → B580 `qwen2.5-coder:7b` → cloud alias | Degrades along quality, not availability: the request always completes, at a stated cost/quality tier. |
| Embeddings | **Tier-1 only.** Never served by the XTX tier, never given a fallback | Vectors from different models are not comparable, so a fallback would silently return *meaningless* retrieval rather than degraded retrieval — the failure has no error and looks like a bad answer. Embeddings are also needed at query time, not just ingestion, so a tier-2 embedding route would break RAG whenever the box sleeps. `nomic-embed-text` is ~275 MB and costs the B580 almost nothing. |
| Health checking | Hub-side background health checks off or on a long interval | A backend down ~20 h/day would otherwise generate constant probe traffic and log noise. |
| Wake | **Manual to start**: Wake-on-LAN from an always-on host (surfaced as a Home Assistant switch) + idle auto-suspend on the box | Request-triggered wake needs a hold-and-forward proxy. Deferred — though k3s makes Sablier a real option for it, where a bare systemd unit did not. |
| Config ownership | **Day-0 in Ansible** (k3s install, Argo CD + root app, `k8s-platform` AppProject, deploy token, Vault token Secret, WoL, gamemode hook, suspend); **day-2 in this repo** (`otter/`) | Same split as the rest of the estate: Ansible owns hosts, Argo CD owns workloads. The AppProject is untracked on the hub too, so this is consistent rather than an exception. |
| Observability | `node_exporter` + `amd_smi` locally; tier availability read from the already-scraped LiteLLM fallback-rate metrics on the hub | "Was it there when I needed it" is a question about the *seam*, which LiteLLM answers. Scraping or remote-writing from a box that is off ~20 h/day would produce mostly-gap series for little gain. |
| Model set | Distinct model names for the 24 GB tier — not aliases shadowing tier-1 names | Which tier answered stays visible in the picker and in metrics; no silent quality swings. |

## Alternatives considered

- **k3s agent joining `homelab`.** Rejected: Talos runs its own PKI and node
  lifecycle, and a node that vanishes at every game launch means permanent
  `NotReady` churn plus hub credentials on the workstation.
- **Hub-managed spoke** (cluster secret + hub Argo CD). Rejected: it moves the
  flapping from kubelet to Argo CD — apps permanently `Unknown`, sync retries
  failing all day — and requires an admin kubeconfig for the box on the hub.
- **Bare Ollama or a Podman Quadlet unit, all config in Ansible.** Viable and
  lighter; rejected because it splits the AI platform across two repos and two
  workflows for the sake of avoiding a control plane on a 64 GB machine. Remains
  the fallback if k3s upkeep on a rolling-release desktop proves too noisy.
- **Ansible-bootstrapped Secret instead of ESO on `otter`.** Would have avoided
  any Vault reachability from the box, but at the cost of the repo's
  secrets-from-Vault convention and a token living in two places. A path-scoped
  read-only Vault token is the narrower trade.

## Scope

**In `yggdrasil`:** `otter/` tree — namespaces, in-cluster Argo CD root app, ESO
+ `ClusterSecretStore`, AMD device plugin, Ollama (ROCm, model PVC), bearer-token
proxy + LAN exposure · LiteLLM `model_list` + fallback chain + fast-fail tuning on
`homelab` · README topology update (a fourth cluster that is explicitly *not* a
spoke).

**Out (ansible-playbooks / host):** k3s install and upgrades · Argo CD +
AppProject + deploy token · Vault token Secret · `nftables` allow-list ·
`gamemode` preempt hook · WoL + idle auto-suspend · `node_exporter`.

**Out (Vault):** the path-scoped read-only policy and token for `otter`.

## Open risks (verify at build time)

1. **VRAM release under gaming** — confirm the hook plus `OLLAMA_KEEP_ALIVE`
   return all VRAM, and that a game launched *during* generation does not stall.
2. **24 GB model choice unproven** — 30B-class MoE vs 32B dense Q4 on tok/s,
   coding quality and usable context.
3. **k3s on a rolling-release desktop.** CachyOS kernel/containerd churn will
   occasionally break the cluster, and k3s's iptables/nft chains interact with
   the host firewall lockdown. If this becomes routine maintenance, fall back to
   the Quadlet alternative above.
4. **Vault reachability is now a dependency of `otter` starting cleanly.** If the
   hub gateway or Vault is down, ESO cannot populate the endpoint token and the
   tier stays down. Acceptable — tier-2 is best-effort by construction — but it
   means `otter` is not truly standalone.
5. **Power economics invert if the box ends up always-on.** The premise is that
   it is otherwise idle *and* asleep. If it drifts to 24/7, buying VRAM for the
   server is the better trade and this ADR should be revisited.

## Consequences

- The local coding tier gets materially better, narrowing ADR-0001's "coding
  quality is bimodal" gap; the cloud alias becomes a rarer escape hatch.
- That improvement is explicitly **best-effort** — tier-2 exists only while the
  workstation is up. The fallback chain makes the degradation graceful, not
  invisible.
- A fourth cluster, and the first one that is **not** a hub-managed spoke. The
  repo now contains a tree no hub `ApplicationSet` reads, which is easy to
  misread as dead code — hence this ADR and the README note.
- `otter` holds two credentials, both read-only and narrowly scoped (this repo,
  one Vault path). The estate's secret handling stays uniform: Vault remains the
  single source of truth, including for LiteLLM's copy of the endpoint token.
- Real GPU telemetry, unlike ADR-0002's passed-through B580 (no MEI/GSC, no power
  limits): bare metal means working `amd_smi` and thermal/power data.
- Adding further backends later costs one `model_list` entry — the seam is now
  exercised by two dissimilar backends rather than assumed.
