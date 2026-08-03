# ADR-0002: Arc B580 passthrough to the Talos GPU node

- **Status:** Accepted
- **Date:** 2026-08-03
- **Cluster:** `homelab` (hub)
- **Resolves:** ADR-0001 "Out (prerequisite)" scope + open risk #3 · issue #886

## Context

ADR-0001 deferred the GPU-node bring-up (Proxmox VFIO passthrough + Talos join)
to the Terraform/Talos tooling. Making the single **Intel Arc B580** (Battlemage,
`8086:e20b`) usable as `gpu.intel.com/xe` inside the `vm-k8s-worker-h6si` Talos
VM (VMID 113 on Proxmox host **gorilla**, AMD EPYC) took a chain of
non-obvious steps — Battlemage passthrough is finicky and each step below was a
hard blocker with a distinctive failure. Recorded so it isn't re-derived.

## Decisions

| Area | Decision | Rationale / failure it fixes |
|---|---|---|
| Host driver bind | `vfio-pci` claims the card **from a cold boot** (persistent `ids=` + `softdep`), host GPU driver never touches it | A runtime `xe`→`vfio-pci` rebind wedges Battlemage MMIO — guest reads `forcewake register 0xFFFFFFFF`, `xe` probe fails `-110`. Only a cold boot with vfio-pci pre-bound yields a clean card. |
| Host config home | Ansible role `pci_passthrough` (ansible-playbooks repo), enabled via gorilla host_var | Reproducible instead of hand-edited; no-op on hypervisors without the var. |
| VM PCIe topology | q35 + OVMF, `hostpci0: 0000:c3:00,pcie=1,rombar=0` | Without `pcie=1` the card lands on a legacy pci-bridge ("unbounded parent pci bridge") → unreachable MMIO. `rombar=0` skips the unassignable option ROM. |
| OVMF MMIO window | `args: -fw_cfg name=opt/ovmf/X-PciMmio64Mb,string=65536` | The 16 GiB VRAM BAR won't map in OVMF's default aperture → firmware hangs before the kernel boots. 64 GiB gives headroom. |
| Guest kernel arg | `xe.probe_display=0` | The `xe` display engine hard-hangs probe on the headless passed-through card (VM freezes right after `xe … vgaarb: VGA decodes changed`). Compute-only is what we want anyway. |
| Kernel-arg delivery | Baked into the **Image Factory schematic** (`customization.extraKernelArgs`), *not* `machine.install.extraKernelArgs` | The cluster uses `grubUseUKICmdline` (UKI); Talos rejects `install.extraKernelArgs` alongside it (`can't be used together`) and the invalid config **blocks all upgrades**. Managed in terraform `src/platform-cluster` (var `talos_extra_kernel_args`). |
| Applying the arg | `talosctl upgrade --image <factory metal-installer image>` | UKI cmdline changes require a reinstall. The stock `ghcr.io/siderolabs/installer` **strips the extensions** — always reuse the factory image. |
| Resizable BAR | Left disabled (BIOS) — didn't matter | Disabled while chasing the hang; `probe_display=0` was the real fix. Inference is compute/VRAM-bandwidth bound, so ReBAR (host→device transfer) is near-irrelevant; can re-enable for marginal load-time gain. |

## Runbook (order matters — each unblocks the next)

1. **BIOS (gorilla):** SVM + IOMMU (AMD CBS → NBIO) + ACS; Above-4G on.
2. **Host vfio bind:** set `pci_passthrough_ids: [8086:e20b, 8086:e2f7]` in
   `host_vars/gorilla/pci_passthrough.yml`, run the Proxmox play, **cold-boot**
   gorilla. Verify `lspci -nnks c3:00.0` → `Kernel driver in use: vfio-pci`.
3. **VM:** `qm set 113 -machine q35 -bios ovmf -cpu host -hostpci0 0000:c3:00,pcie=1,rombar=0`
   and `-args '-fw_cfg name=opt/ovmf/X-PciMmio64Mb,string=65536'`.
4. **Kernel arg:** `talos_extra_kernel_args = ["xe.probe_display=0"]` → terraform
   apply → `talosctl upgrade --image <new factory image>`; confirm in
   `/proc/cmdline`.
5. **Verify:** `[drm] Initialized xe 1.1.0`; `/dev/dri/renderD128` present; node
   advertises `gpu.intel.com/xe: 1`.

Full host-side detail: `roles/pci_passthrough/README.md` in the ansible-playbooks repo.

## Consequences

- The B580 is schedulable (`gpu.intel.com/xe`), unblocking Ollama (#884). The
  node keeps `derwitt.site/ai=true`; NFD auto-stamps `intel.feature.node.kubernetes.io/gpu`.
- **No GPU power-management telemetry in the guest**: dmesg shows recurring
  `PCODE Mailbox failed … Illegal Command` / "Failed to read power limits" and
  "missing mei component" — the MEI/GSC isn't in the VM. Non-fatal for compute;
  it means no dynamic power-limit control and possibly a fixed clock/power state.
- ADR-0001 open risk #2 (Ollama Vulkan correctness + tok/s on Battlemage, #885)
  is still open and now testable end-to-end — validate real output before
  trusting throughput, since power management is degraded.
- The kernel arg rides the shared schematic, so it lands (inert) on every node's
  image; nodes converge on their next `talosctl upgrade`.
