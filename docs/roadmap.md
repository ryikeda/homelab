# Homelab roadmap

Target end state and the order it'll get built in. Ansible (`iac/ansible/`) handles Proxmox host prep and OPNsense config; OpenTofu (`iac/opentofu/`) handles VM/container provisioning on top of it.

## Target services

- A k3s Kubernetes cluster running the main services.
- A GPU-passthrough VM for workloads that need the card: Jellyfin, Ollama.
- Portainer, likely on the GPU VM alongside Docker.
- OPNsense (bare metal, on a separate multi-NIC mini PC) as router/firewall, with 3 VLANs: main, iot, cameras.
- Technitium DNS Server for local DNS + ad-blocking, virtualized as a Proxmox VM.
- WireGuard for remote access into the home network.
- Cloudflare Tunnel for exposing specific self-hosted services to the public internet, without a full VPN connection.

## Decisions made

- **Kubernetes distribution: k3s.** Lightweight, easy to bootstrap, low overhead for homelab-sized VMs. Single cluster (control-plane + 2 workers), no Rancher - see `docs/k3s-cluster-plan.md` for the full reasoning (single physical host, single cluster, explicit goal of learning core k8s operations rather than a vendor management layer on top). Argo CD runs in-cluster for GitOps app delivery.
- **Remote access: WireGuard, self-hosted.** Full control, no third-party coordination service.
- **Public exposure: Cloudflare Tunnel**, for the subset of services meant to be reachable from the internet (not full network access like WireGuard) - matches the DNS naming split in `network.md` (`*.ikeda.codes`/`*.home.ikeda.codes` for tunneled services vs `*.local.ikeda.codes` for internal-only).
- **Router/firewall: OPNsense, bare metal** on the spare multi-NIC mini PC — not virtualized, to avoid a circular dependency where a Proxmox reboot takes down the router that Proxmox itself needs to be reachable. The existing consumer router gets demoted to Wi-Fi-only Access Point mode (DHCP/NAT disabled, connected via a LAN port), so OPNsense stays the single source of routing/DHCP/DNS-forwarding.
- **VLANs: main, iot, cameras**, each its own subnet (e.g. `10.10.10.0/24`, `10.10.20.0/24`, `10.10.30.0/24`) trunked over one NIC to OPNsense, with per-VLAN DHCP scopes. Wi-Fi VLAN segmentation (separate SSIDs per VLAN) depends on whether the existing router's AP mode supports VLAN-tagged SSIDs — needs checking against the actual router model.
- **DNS: Technitium DNS Server**, virtualized as a Proxmox VM (not the mini PC — smaller blast radius if briefly down during Proxmox maintenance, reuses existing storage/backups). Chosen over Pi-hole/AdGuard Home and over OPNsense's built-in Unbound because its REST API supports proper zone/record CRUD, which is what's needed to programmatically register DNS records when OpenTofu/Ansible provision a new VM.
- **OPNsense configuration via Ansible** (`ansibleguy.opnsense` collection, or equivalent — verify current best option when this step starts), not the web UI — VLANs, firewall rules, and DHCP scopes as code, same pattern already used for Proxmox. Requires enabling OPNsense's REST API and minting an API key/secret first, the same one-time bootstrap shape as the `opentofu@pve` token.

## Build order

Each step should be independently testable before moving to the next.

0. **OpenTofu project scaffolding** (`iac/opentofu/`) — `bpg/proxmox` provider authenticated with the `opentofu@pve` API token (from `proxmox_opentofu_user`), state storage, and a `tofu plan` that talks to Proxmox with nothing to build yet. *Done.*
1. **First VM: the GPU workload box** — clone the `ubuntu-2404` template (from `proxmox_vm_template`), attach the `gpu0` PCI resource mapping (from `proxmox_gpu_passthrough`), cloud-init for user/SSH/DHCP. *Done* — `ubuntu-2404-gpu-box` is running at a DHCP-assigned address, GPU visible in-guest (`lspci` shows `10de:1c03`), guest agent responding. Two fixes needed along the way, both now baked into `vm_gpu_box.tf`:
   - The template's `vga = serial0` (no emulated display) means the passthrough GPU is the only display device, and SeaBIOS hangs trying to run its legacy VBIOS option ROM. Fixed by overriding firmware to `bios = "ovmf"` + an `efi_disk` block for this VM.
   - Ubuntu's cloud image doesn't reliably ship `qemu-guest-agent`. Fixed with a cloud-init vendor-data snippet (`files/vendor-data-qemu-guest-agent.yaml`, uploaded via `proxmox_virtual_environment_file`) that installs and enables it on first boot. Uploading to the `snippets` content type needs SSH (no API upload endpoint for it), so the provider's `ssh` block reuses the existing `ansible` identity — this required adding `snippets` to `local`'s content types via `proxmox_storage_content` (Ansible).
2. **OPNsense bare metal + VLANs** — install OPNsense on the mini PC (ended up as dedicated physical ports per network, not VLAN trunking - see `network.md`), configure interfaces, DHCP scopes, and firewall rules via Ansible (`opnsense_firewall`/`opnsense_dnsmasq`/`opnsense_unbound` roles). *Done.*
3. **Technitium DNS VM** — cloned like `gpu-box` but with a static IP, self-installs via an OpenTofu provisioner chain. DNS records managed via its REST API (`playbooks/dns_record.yml`/`dns_records.yml`), OPNsense's Unbound forwards the internal zone to it. *Done.*
4. **WireGuard remote access** — self-hosted VPN, own VM (not an OPNsense plugin - keeps the one thing exposed to WAN traffic isolated with its own kernel). *Blocked, design revised*: the ISP router runs in MAP-E mode (carrier-grade NAT), which has no inbound port forwarding at all and no IPv6 passthrough on OPNsense's WAN - a directly-reachable inbound WireGuard server on the home LAN isn't possible. Revised plan adds a small external relay VPS (real public IP, Tokyo/Osaka region for latency) as the WireGuard hub: phone/laptop clients connect to the VPS, and the home-LAN VM dials out to it as a client (instead of listening for inbound connections) with a persistent keepalive, still masquerading tunnel traffic onto the LAN as originally planned. See `network.md`'s WireGuard section for the full reasoning and tradeoffs versus Cloudflare Tunnel/NetBird. Not yet built. Prioritized ahead of GPU VM software/k3s.
5. **Software on the GPU VM** — Docker, the NVIDIA driver, Dockge, Jellyfin, Ollama. *Done* — `playbooks/gpu_services.yml` (`iac/ansible/README.md` has the full breakdown). Notable along the way:
   - **Portainer swapped for Dockge** — lighter-weight, manages `docker-compose.yml` stacks directly instead of wrapping them in a heavier abstraction.
   - **`--gpus all` doesn't work on this Docker version** — fails with `AMD CDI spec not found` even for an NVIDIA-only host, because Docker now resolves GPU requests through CDI rather than the legacy runtime hook. Fixed by generating an NVIDIA CDI spec (`nvidia-ctk cdi generate`) and requesting the GPU by its CDI-qualified name (`devices: [nvidia.com/gpu=all]`) in every compose file instead.
   - **GPU VM resized and moved to a static IP** — 4 cores/8GB → 8 cores/24GB/150GB disk (host has 28 cores/125GB total, plenty of headroom left for k3s later), `10.10.10.54/24` instead of DHCP, renamed `ubuntu-2404-gpu-box` → `gpu-box` in both Proxmox and (via a new `common` role task) the guest OS itself.
   - **Jellyfin's media library is NAS-mounted**, not on the VM's own disk — read-only NFS mount (`10.10.10.50:/volume1/jellyfin`), consistent with keeping VM disks small and media on existing NAS storage/backups.
   - **Ollama models are declared in git** (`ollama_models` in `group_vars/gpu.yml`) and auto-pulled — `llama3.2:3b`, `llama3.1:8b`, `qwen2.5:7b`, sized to fit the GTX 1060's 6GB VRAM. Its API has no auth, so it stays LAN-only for now — not a candidate for Cloudflare Tunnel exposure (step 7) without an auth layer in front of it.
   - Memory ballooning (`floating`) added to gpu-box and Technitium so Proxmox's dashboard reflects real in-guest usage instead of always showing the full static allocation as "used".
6. **k3s cluster** — control-plane + 2 workers, cloned from the VM template and bootstrapped with k3s directly (no Rancher). *Done* — `gondor`/`rohan`/`shire` are up and `Ready`. Argo CD installed in-cluster for GitOps app delivery, built but not yet applied - no workload decided yet. Full design in `docs/k3s-cluster-plan.md`.
7. **Cloudflare Tunnel** — a way to access self-hosted services from outside the home network without a full VPN connection. Expose specific services under `*.ikeda.codes`/`*.home.ikeda.codes` (see `network.md`'s DNS naming section), fronted by Cloudflare Access/Tunnel rather than port-forwarding anything on OPNsense's WAN directly. For later, after WireGuard.

## Prerequisites already in place (Ansible, `iac/ansible/`)

- `proxmox_admin_user` — the `ansible@pam` management user Ansible connects as.
- `proxmox_storage` — `local-vmstore` LVM storage on the second disk, for VM/container disks.
- `proxmox_gpu_passthrough` — IOMMU/vfio-pci host prep and the `gpu0` resource mapping for the GTX 1060.
- `proxmox_vm_template` — the `ubuntu-2404` cloud-init VM template (vmid 9000).
- `proxmox_lxc_template` — the `ubuntu-24.04-standard` LXC container template.
- `proxmox_backup` — NFS backup storage (NAS) and a nightly `vzdump` job.
- `proxmox_opentofu_user` — the `opentofu@pve` API user/token OpenTofu will authenticate with.
