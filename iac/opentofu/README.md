# OpenTofu Homelab IaC

Provisions VMs/containers on Proxmox on top of the host prep done by `iac/ansible/` (storage, GPU passthrough, VM/LXC templates — see `../ansible/README.md`).

## Requirements

- [OpenTofu](https://opentofu.org/) installed (`tofu version`).
- The `opentofu@pve` API token, minted by the `proxmox_opentofu_user` Ansible role and saved to `~/.proxmox/opentofu.env` (outside this repo, not committed).

## Usage

The provider reads `PROXMOX_VE_ENDPOINT` and `PROXMOX_VE_API_TOKEN` from the environment rather than from any file in this repo, so source the token before running any command:

```sh
set -a
source ~/.proxmox/opentofu.env
set +a

tofu init
tofu plan
tofu apply
```

If that token file is missing or lost, re-run `ansible-playbook playbooks/proxmox.yml --limit pve` from `iac/ansible/` with a new `opentofu_token_name` to mint a replacement (see that role's README section).

## Linting

`.github/workflows/ci.yml` runs `tofu fmt -check -recursive` and `tofu validate` on every PR/push - format and internal-consistency checks only, no `plan`/`apply` (that needs real Proxmox credentials CI doesn't have). Run the same checks locally with `tofu fmt -recursive` and `tofu validate` (needs `tofu init -backend=false` first if `.terraform/` isn't already there).

## State

State is local (`terraform.tfstate` in this directory) — fine for a single operator. It's gitignored, along with `.terraform/` and any `*.tfvars`. `.terraform.lock.hcl` **is** committed, so provider version resolution stays reproducible.

## Layout

- `versions.tf` — OpenTofu/provider version constraints.
- `providers.tf` — the `proxmox` provider block (`insecure = true` by default, since Proxmox's default cert is self-signed; set `proxmox_insecure = false` once a real certificate is installed).
- `variables.tf` — shared inputs (`pve_node`, `proxmox_insecure`).
- `main.tf` — currently just a `proxmox_version` data source/output as a connectivity smoke test.

## VMs and containers

Every VM/LXC resource sets an explicit `vm_id` rather than leaving Proxmox to auto-assign one, grouped by range so an ID alone signals what tier something belongs to:

| Range | Purpose |
|---|---|
| `100-199` | Core infrastructure — always-up, foundational, not casually rebuilt |
| `200-299` | Workload VMs — GPU/compute, disposable/rebuildable |
| `300-399` | k3s cluster (roadmap step 6) — one contiguous block per cluster |
| `9000-9099` | VM/LXC templates (`proxmox_vm_template`/`proxmox_lxc_template` Ansible roles) |

Current assignments:

| ID | Resource | File | Type | Purpose |
|---|---|---|---|---|
| 100 | gpu-box | `vm_gpu_box.tf` | VM | Docker + NVIDIA GPU passthrough — Jellyfin, Ollama, Open WebUI, Portainer agent |
| 102 | technitium | `vm_technitium.tf` | VM | Internal DNS |
| 103 | traefik | `lxc_traefik.tf` | LXC | Reverse proxy, DNS-01 certs |
| 104 | palantir | `vm_palantir.tf` | VM | Prometheus + Grafana |
| 105 | portainer | `lxc_portainer.tf` | LXC | Docker fleet management (gpu-box + palantir as Environments) |
| 300 | gondor | `vm_k3s_prod.tf` | VM | k3s control-plane |
| 301 | rohan | `vm_k3s_prod.tf` | VM | k3s worker |
| 302 | shire | `vm_k3s_prod.tf` | VM | k3s worker |
| 9000 | ubuntu-2404 | (Ansible: `proxmox_vm_template`) | VM template | Base image every VM above is cloned from |

`gpu-box` predates this convention and technically belongs in `200-299` by purpose — left at `100` rather than renumbered, since changing a live VM's ID means clone/migrate for no functional benefit. New resources should pick from the ranges above, not auto-assign.
