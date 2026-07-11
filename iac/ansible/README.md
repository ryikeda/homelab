# Ansible Homelab IaC

This directory manages homelab configuration with Ansible.

## Layout

- `inventories/homelab/hosts.yml`: source of truth for host membership.
- `inventories/homelab/group_vars/`: shared and group-specific configuration.
- `playbooks/`: thin orchestration layers that assign roles to groups.
- `roles/`: reusable configuration and operations logic.
- `collections/requirements.yml`: Ansible collection dependencies.

## Requirements

- Install `sshpass` if bootstrapping with password-based SSH:
  `brew install sshpass`
- Install collections:
  `ansible-galaxy collection install -r collections/requirements.yml -p collections`

## Usage

Run commands from this directory:

Create a local variables file before running playbooks. Ansible loads this automatically from `group_vars`, so no export or wrapper script is needed:

```sh
cp inventories/homelab/group_vars/all/local.yml.example inventories/homelab/group_vars/all/local.yml
```

```sh
ansible-playbook playbooks/bootstrap.yml
ansible-playbook playbooks/proxmox.yml
ansible-playbook playbooks/maintenance.yml
ansible-playbook playbooks/health.yml
```

To run a playbook against a single host, use `--limit` with the inventory host name:

```sh
ansible-playbook playbooks/bootstrap.yml --limit pve
ansible-playbook playbooks/proxmox.yml --limit pve
ansible-playbook playbooks/health.yml --limit pve
```

For Proxmox hosts, run `bootstrap.yml` first to create the OS admin user, then `proxmox.yml` to register that user in Proxmox and assign its ACL.

After bootstrap, Proxmox hosts connect as the managed `ansible` user with the configured SSH key. For a first-time bootstrap before that user exists, override the connection user at the command line:

```sh
ansible-playbook playbooks/bootstrap.yml --limit pve -u root -e ansible_password='your-root-password'
```

The default inventory is configured in `ansible.cfg`.

## Adding Hosts

Add hosts to the relevant logical group in `inventories/homelab/hosts.yml`, then put reusable settings in `group_vars/all.yml` or the matching group file.

## Secrets

Do not commit real passwords, password hashes, tokens, or private IP addresses if you consider them sensitive. Use `inventories/homelab/group_vars/all/local.yml` for local values; it is ignored by git.

`admin_user_password_hash` must be a Linux password hash, not the plaintext password. Generate it locally with:

```sh
mkpasswd --method=yescrypt
```

or:

```sh
openssl passwd -6
```

Then put the hash in `inventories/homelab/group_vars/all/local.yml` as `admin_user_password_hash`. Use the original plaintext password when logging into Proxmox as `ansible@pam`.

## OpenTofu automation user

`playbooks/proxmox.yml` also runs the `opentofu_user` role, which creates a separate `opentofu@pve` Proxmox user (PVE realm, API token only, no SSH/shell access) scoped to a custom `Terraform` role instead of `Administrator`. This keeps OpenTofu's credentials independent from the `ansible` user used for host/SSH management.

On first run it mints an API token and writes it to `~/.proxmox/opentofu.env` on the controller (outside this repo, not committed). Proxmox only shows a token's secret once at creation, so if that file is lost, either recover the value from wherever OpenTofu's provider config was pointed at it, or delete the token with `pveum user token remove opentofu@pve provider` on the Proxmox host and re-run `ansible-playbook playbooks/proxmox.yml` to mint a replacement.

## VM storage disks

`playbooks/proxmox.yml` also runs the `proxmox_storage` role, which turns a spare disk/partition into an LVM-backed Proxmox storage pool for VM disk images and container rootdirs (equivalent to `pvcreate` + `vgcreate` + `pvesm add lvm`). It's off by default (`proxmox_storage_manage: false`); enable it per host with a `proxmox_storage_disks` list, e.g. in `inventories/homelab/host_vars/<hostname>.yml`:

```yaml
proxmox_storage_manage: true
proxmox_storage_disks:
  - device: /dev/sdb1
    vg_name: vmstore
    storage_id: local-vmstore
    content: images,rootdir
```

Add one list entry per disk to cover additional drives. The role refuses to touch a device that already carries a filesystem signature other than `LVM2_member`, so it won't silently overwrite data — wipe the disk manually first (`wipefs -a <device>`) once you're sure it's unused. Everything else is idempotent: existing PVs, VGs, and registered storage IDs are detected and left alone.

## GPU passthrough (host prep)

`playbooks/proxmox.yml` also runs the `proxmox_gpu_passthrough` role, which prepares the host so a GPU can later be passed through to a VM: it enables IOMMU on the kernel command line, blacklists the GPU's native driver, and binds the card's PCI IDs to `vfio-pci`. It only touches the host side — actually attaching the device to a specific VM (the `hostpci0` config) is a per-VM concern that belongs in OpenTofu when you provision that VM, not here.

It's off by default; enable it per host once you know the GPU's PCI IDs and CPU vendor:

```sh
lspci -nnk | grep -A3 -Ei 'vga|3d|display'   # PCI [vendor:device] IDs
grep -m1 -Ei 'vendor_id' /proc/cpuinfo        # GenuineIntel or AuthenticAMD
```

```yaml
proxmox_gpu_passthrough_manage: true
proxmox_gpu_passthrough_iommu_vendor: intel   # or amd
proxmox_gpu_passthrough_pci_ids:
  - "10de:1c03"   # include any sibling function too, e.g. an HDMI audio controller
```

Applying this role changes the kernel command line and initramfs, so it always requires a reboot to take effect. The role does not reboot for you; when it reports changes, run:

```sh
ansible-playbook playbooks/reboot.yml --limit pve
```

Once the card shows `Kernel driver in use: vfio-pci` (check with `lspci -nnk -s <bus-id>`), the role also registers it as a named **Resource Mapping** (`proxmox_gpu_passthrough_mapping_name`, default `gpu0`) via `pvesh`/`/cluster/mapping/pci`. VMs should reference this mapping (Datacenter → Resource Mappings, or VM → Hardware → Add → PCI Device → Mapped Device) instead of the raw PCI address, so passthrough keeps working if the card ever ends up in a different slot. Set `proxmox_gpu_passthrough_mapping_name: ""` to skip creating a mapping.

This role only covers host-side prep. Two steps stay outside it, to remember when a VM needs the GPU:

- **OpenTofu**: the VM resource needs a `hostpci` block that references the mapping by name (e.g. `mapping = "gpu0"`), not a raw PCI ID — that's the Terraform-side equivalent of picking "Mapped Device" in the UI.
- **Guest driver install**: attaching the PCI device just makes it visible to the VM; the guest still needs its own GPU driver installed and the VM rebooted before anything (e.g. `nvidia-smi`) can use it. That's a per-VM, post-boot step (cloud-init script or a guest-facing Ansible role), not something this host-level role should do.
