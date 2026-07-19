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

`playbooks/proxmox.yml` also runs the `proxmox_opentofu_user` role, which creates a separate `opentofu@pve` Proxmox user (PVE realm, API token only, no SSH/shell access) scoped to a custom `Terraform` role instead of `Administrator`. This keeps OpenTofu's credentials independent from the `ansible` user used for host/SSH management.

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

The same role can also converge content types on storage that already exists, rather than creating anything new — e.g. enabling `snippets` on the built-in `local` storage so OpenTofu can upload cloud-init vendor-data files:

```yaml
proxmox_storage_content:
  local:
    - iso
    - vztmpl
    - backup
    - import
    - snippets
```

Each value is the *full* desired content type list for that storage id (`pvesm set --content` replaces the list, it doesn't append) — the role only runs `pvesm set` when the current list differs from what's declared.

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

## VM templates

`playbooks/proxmox.yml` also runs the `proxmox_vm_template` role, which downloads a cloud image and turns it into a Proxmox VM template (`qm importdisk` + a cloud-init drive + `qm template`) that OpenTofu can clone per VM. It's off by default; enable it with a `proxmox_vm_templates` list, one entry per OS:

```yaml
proxmox_vm_templates_manage: true
proxmox_vm_templates:
  - name: ubuntu-2404
    vmid: 9000
    image_url: https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
    storage: local-vmstore
    disk_size: 20G

  - name: debian-12
    vmid: 9001
    image_url: https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2
    storage: local-vmstore

  - name: arch
    vmid: 9002
    image_url: https://geo.mirror.pkgbuild.com/images/latest/Arch-Linux-x86_64-cloudimg.qcow2
    storage: local-vmstore
```

Each entry is independent — add as many OSes as you want, each with its own `vmid`, image, storage target, and sizing (see `roles/proxmox_vm_template/defaults/main.yml` for every field, including `bios: ovmf` for UEFI images and `cloud_init: false` for images that don't use it). Matching is by `vmid`: once a template with that ID exists, the role leaves it alone — delete the VM and re-run to rebuild it, there's no in-place drift correction for VM hardware.

Verify the image URLs and, where available, pin an `image_checksum` (e.g. `"sha256:<hex>"`, passed straight to Ansible's `get_url`) before enabling this in your own `host_vars` — these are convenience examples, not vetted for your setup.

## LXC container templates

These are a different artifact from the VM templates above — an LXC container is built from a rootfs tarball (`vztmpl` content type), cloned via `pct create`/`pct clone`, not the qcow2/raw disk images `qm clone` uses. `playbooks/proxmox.yml` also runs the `proxmox_lxc_template` role for these, using Proxmox's own appliance catalog (`pveam`) instead of a raw download URL:

```yaml
proxmox_lxc_templates_manage: true
proxmox_lxc_template_storage: local   # must have the vztmpl content type
proxmox_lxc_templates:
  - ubuntu-24.04-standard_24.04-1_amd64.tar.zst
```

Template filenames are versioned and change over time, so look up the current one before adding it:

```sh
pveam update && pveam available --section system | grep -i ubuntu
```

The role runs `pveam update` to refresh the catalog, then downloads only the filenames in the list that aren't already present on that storage — idempotent, and safe to add more entries later. It's off by default and not yet enabled for any host.

## NFS backup storage and backup jobs

`playbooks/proxmox.yml` also runs the `proxmox_backup` role, which registers a NAS's NFS export as Proxmox storage and configures `vzdump` backup jobs (Datacenter → Backup) against it:

```yaml
proxmox_backup_manage: true
proxmox_backup_nfs_storage_id: nas-backup
proxmox_backup_nfs_server: 192.168.1.50
proxmox_backup_nfs_export: /volume1/proxmox-backup

proxmox_backup_jobs:
  - id: daily-vm-backup
    schedule: "02:00"
    storage: nas-backup
    guests: all
    mode: snapshot
    compress: zstd
    retention: "keep-last=7,keep-daily=7,keep-weekly=4,keep-monthly=6"
```

The storage registration is idempotent (checked against `pvesm status`) and installs `nfs-common` if missing; it also runs `showmount -e` first and just warns (doesn't block) if the export isn't visible, since `pvesm add` will fail loudly on its own if the mount is actually broken. Set `proxmox_backup_manage_nfs_storage: false` if the storage is already registered and you only want this role to manage jobs.

Backup jobs are matched by `id` and, like the VM/LXC templates, only created once — the role won't touch an existing job's schedule/retention/etc. To change one, edit or delete it directly on the host (`pvesh set /cluster/backup/<id> ...` or `pvesh delete /cluster/backup/<id>`) and re-run to recreate it. `guests: all` backs up every VM/container; give it a list of vmids (e.g. `[100, 101]`) to scope it instead. It's off by default and not yet enabled for any host — you'll need your NAS's real IP and export path before turning it on.

## OPNsense configuration

`playbooks/opnsense.yml` configures OPNsense itself via its REST API (the `ansibleguy.opnsense` collection), not SSH — OPNsense isn't a Proxmox host, so it's a separate playbook/inventory group (`fw`) from everything above, and tasks run locally on the controller rather than on the target. Each concern is its own role (`opnsense_firewall`, `opnsense_dnsmasq`, ...), the same one-role-per-concern pattern as the `proxmox_*` roles above, since OPNsense covers several independent subsystems that'll keep growing separately. Shared API connection settings (`opnsense_api_port`, `opnsense_api_credential_file`, `opnsense_ssl_verify`) live once in `inventories/homelab/group_vars/opnsense.yml` rather than duplicated per role.

Getting to a reachable, automatable OPNsense has real prerequisites none of these roles can do for you — none of this is automatable the way `proxmox_opentofu_user` mints its own token, because there's no existing Ansible foothold on OPNsense until these steps are done by hand:

1. **Install OPNsense** on its own hardware and, via its console, assign interfaces and give each a static address (option 1, then option 2 in the console menu). See `../../docs/network.md` for the full network design and current IP assignments. These roles assume OPNsense is already reachable over HTTPS on its LAN address.
2. **System → Access → Groups**: create a dedicated group (e.g. `automation`) and grant it only the privileges actually needed for what's being automated (e.g. "Firewall: Rules" for `opnsense_firewall`) — not the built-in `admins` group.
3. **System → Access → Users**: create a user (e.g. `ansible`), assign it to that group, leave shell access disabled — it only ever needs the API key, never a login shell.
4. On that user's page, generate an **API key** — the key/secret are shown only once, downloaded as a text file.
5. Save that file outside this repo, e.g. `~/.opnsense/ansible.env`, and lock down its permissions (`chmod 600`). It's already in the exact `key=...` / `secret=...` format the `ansibleguy.opnsense` modules expect via `api_credential_file` — no reformatting needed.

Then set `opnsense_host` in `inventories/homelab/group_vars/all/local.yml` (see `local.yml.example`) and run:

```sh
ansible-playbook playbooks/opnsense.yml --diff
```

### Firewall rules (`opnsense_firewall`)

Declared as a list, matched by `description` (like the VM/LXC templates and backup jobs above are matched by name/id):

```yaml
opnsense_firewall_manage: true
opnsense_firewall_rules:
  - description: Allow LAN to CAMERAS (NVR access)
    interface: [lan]
    action: pass
    source_net: any
    destination_net: "{{ opnsense_cameras_subnet }}"
```

Only rules that need to actively *allow* something go here — per `docs/network.md`, OPNsense's default deny-all on every new interface already handles isolation (e.g. CAMERAS/IOT can't reach LAN or WAN) without any explicit block rules.

`ansibleguy.opnsense.rule` requires a `match_fields` argument identifying which fields count as "this is the same rule" for idempotency checks (it's not defaulted upstream, and omitting it fails with a cryptic `'NoneType' object is not iterable`) — the role always passes `match_fields: [description]`, matching how rules are keyed here.

### DHCP ranges (`opnsense_dnsmasq`)

Declared the same way, matched by `description`:

```yaml
opnsense_dnsmasq_manage: true
opnsense_dnsmasq_ranges:
  - description: LAN DHCP range
    interface: LAN
    start_addr: "{{ opnsense_lan_dhcp_start }}"
    end_addr: "{{ opnsense_lan_dhcp_end }}"
```

This targets **dnsmasq**, not Kea — OPNsense 26.1 defaults new installs' DHCPv4 to dnsmasq (the modern replacement direction for the deprecated ISC `dhcpd`), and the console's DHCP-enable wizard configures dnsmasq accordingly. The collection's `dhcp_subnet`/`dhcp_reservation` modules exist too but target Kea specifically (`API_MOD = 'kea'`) — they won't see or manage a dnsmasq-backed scope. The `dnsmasq_*` modules are labeled "unstable" upstream (less community testing, not "known broken"); switching the actual DHCP backend to Kea just to use the "stable"-labeled modules wasn't judged worth the migration effort for a homelab that doesn't need Kea's failover/DHCPv6-PD features.

Note `dnsmasq_range`'s `interface` field matches by **display name** (`"LAN"`, `"CAMERAS"`, `"IoT"` — whatever each interface's Description field is set to), not the lowercase assignment key (`lan`) that `opnsense_firewall`'s `rule` module uses — these two modules use different conventions for the same underlying interface.

Every run shows a cosmetic diff on `ra_mode` (`[] -> ""`) for each range — a type-normalization quirk in the module for an IPv6 Router Advertisement field none of our (IPv4-only) ranges set. Harmless; not a real change each time.

### Python interpreter requirement

The `ansibleguy.opnsense` modules need the `httpx` Python package. If the interpreter Ansible normally uses doesn't have it installed, set `opnsense_ansible_python_interpreter` in `local.yml` to one that does — this is deliberately not defaulted in `main.yml`, since a default there would silently take precedence over a `local.yml` override (files in the same `group_vars/all/` directory load in alphabetical order, with later files winning on shared keys — `local.yml` loads before `main.yml`).

### Not yet automated: interface assignment

Renaming/describing a base physical interface (e.g. `OPT1` → `CAMERAS`) or setting its IPv4 address has no supported module in this collection — only virtual interface types (VLAN, bridge, LAGG, etc.) are covered. This stays a manual console/GUI step for now; not worth building on the collection's `raw`/unstable escape hatch for something this foundational to network connectivity.
