# OpenTofu Homelab IaC

Provisions VMs/containers on Proxmox on top of the host prep done by `iac/ansible/` (storage, GPU passthrough, VM/LXC templates — see `../ansible/README.md` and `../../docs/roadmap.md`).

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

## State

State is local (`terraform.tfstate` in this directory) — fine for a single operator. It's gitignored, along with `.terraform/` and any `*.tfvars`. `.terraform.lock.hcl` **is** committed, so provider version resolution stays reproducible.

## Layout

- `versions.tf` — OpenTofu/provider version constraints.
- `providers.tf` — the `proxmox` provider block (`insecure = true` by default, since Proxmox's default cert is self-signed; set `proxmox_insecure = false` once a real certificate is installed).
- `variables.tf` — shared inputs (`pve_node`, `proxmox_insecure`).
- `main.tf` — currently just a `proxmox_version` data source/output as a connectivity smoke test; will grow into the actual VM/container resources described in `../../docs/roadmap.md`.
