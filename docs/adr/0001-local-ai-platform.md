# ADR-0001: Local AI platform

- **Status:** Accepted
- **Date:** 2026-08-01
- **Cluster:** `homelab` (hub)

## Context

We want a self-hosted AI platform serving three consumers: an OpenAI-compatible
inference **API for other apps** (Home Assistant Assist, Paperless, etc.), a
**personal chat UI**, and a **coding-assistant backend**. Available acceleration
is a single **Intel Arc B580** (Battlemage, 12 GB VRAM) — no CUDA, no NVIDIA
tooling. The GPU node is not yet built; the Talos image for `platform-cluster`
already bakes the Intel GPU stack (`intel-ucode`, `i915`, `xe`, `mei`).

Key constraints:

- **No CUDA.** Intel inference means the Vulkan or SYCL/IPEX-LLM path.
- **12 GB VRAM** holds ~one 7B–14B model at Q4 — decent chat, adequate coding,
  not frontier. Can't hold chat + coding + embeddings simultaneously.
- **Battlemage is new**: fully supported on kernel ≥6.13 + Mesa >24.

## Decisions

| Area | Decision | Rationale |
|---|---|---|
| Inference engine | **Ollama upstream + Vulkan** (`OLLAMA_VULKAN=1`) | OpenAI-compatible, model auto-swap (fits one GPU / many uses), upstream image is Renovate-trackable. IPEX-LLM SYCL fork held as a perf fallback. |
| Backbone | **LiteLLM** gateway | Stable OpenAI-compatible seam for all consumers; per-consumer virtual keys, budgets, model aliasing; the single point to add cloud routing. Front-ends stay pluggable behind it. |
| Cloud routing | **Hybrid, opt-in aliases** | Local by default; explicit cloud aliases (e.g. `coding-large` → Anthropic/Gemini) fill the gap the 12 GB GPU can't. Provider keys in Vault. Preserves local-first posture with an escape hatch. |
| Chat UI | **Open WebUI** (interim) | Cheap usable surface day one; authentik OIDC; talks to LiteLLM. Does not preclude adopting Turnstone. |
| Front-ends | **Pluggable; Turnstone = evaluate later** | Turnstone is an agent-orchestration platform (a model *consumer*, not an OpenAI *source*) and ships Compose/Python/Git-LFS with no Helm chart. Kept as a candidate, not a committed component. |
| Observability | **VictoriaMetrics scrape of LiteLLM Prometheus metrics** | Reuses the existing stack. Langfuse (Postgres + ClickHouse) deferred until prompt-level tracing is actually wanted. |
| Cluster | **homelab** | Hub; co-located with Vault/CNPG/garage/VM-metrics. GPU workloads `nodeSelector`-pinned. |
| Exposure | **Standard app exposure** (Traefik/Gateway route, cert-manager, external-dns) | Reachability is gated below the cluster (WireGuard + DNS on the worker LB); the cluster treats it like any other app. authentik SSO fronts human UIs. |
| Storage | **proxmox-data PVC (~200 Gi)** for models · Open WebUI small PVC · LiteLLM on CNPG | Ollama needs a filesystem for weights; RWO PVC pinned to the GPU node. |
| Namespace | **`ai-platform`** | One namespace for the platform, per the per-app namespace convention. |
| Sequencing | **Build now, cloud-first** | LiteLLM + UI + cloud aliases are useful before the GPU exists; Ollama sits `Pending` until the node is labeled, then local inference activates with no repo changes. |

## Scope

**In `yggdrasil` (this repo):** Intel GPU device plugin · Ollama (Vulkan, GPU
request, node pin, model PVC) · LiteLLM + CNPG Postgres + Vault secrets ·
Open WebUI · authentik OIDC · Gateway route + cert + DNS · VM metrics scrape.

**Out (Terraform/Talos tooling, prerequisite):** Proxmox VFIO passthrough ·
Talos node join · node label. Driver baking is already done in the
`platform-cluster` schematic.

## Open risks (verify at build time)

1. **Talos baked kernel ≥6.13** for full Battlemage support (Mesa userspace
   ships in the Ollama container, not the host).
2. **Ollama Vulkan on Battlemage** — stock `ollama/ollama` has open reports of
   Vulkan-on-Intel gibberish; the image/Mesa combo needs a spike, with the
   IPEX-LLM SYCL image as the fallback.
3. **Intel device-plugin `xe` scheduling** — confirm plugin version exposes the
   B580 (resource name, optional fractional `shared-dev-num`).

## Consequences

- One stable OpenAI endpoint (LiteLLM) that every consumer and front-end
  attaches to; front-end churn (incl. a future Turnstone) costs no rework.
- Platform is useful immediately (cloud-first) and self-upgrades to local
  inference when the GPU node lands.
- Coding quality is bimodal: local for privacy/cheap, cloud alias for hard
  problems — an explicit, per-alias choice rather than a silent ceiling.
