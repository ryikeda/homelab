# Ansible Homelab IaC

This directory manages homelab configuration with Ansible.

## Layout

- `inventories/homelab/hosts.yml`: source of truth for host membership.
- `inventories/homelab/group_vars/`: shared and group-specific configuration.
- `playbooks/`: thin orchestration layers that assign roles to groups.
- `roles/`: reusable configuration and operations logic.
- `collections/requirements.yml`: Ansible collection dependencies.
- `pyproject.toml`/`uv.lock`: Python dependencies for running Ansible itself (`ansible-core`, `httpx`) - reproducible via `uv`, not whatever happens to be on the operator's machine. The `dev` dependency group (`ansible-lint`, `yamllint`) is CI/local-lint tooling, not needed to actually run playbooks.
- `.ansible-lint`/`.yamllint`: lint config, also used by `.github/workflows/ci.yml`.

## Requirements

- Install [`uv`](https://docs.astral.sh/uv/), then sync the Python environment: `uv sync`
- Install `sshpass` if bootstrapping with password-based SSH:
  `brew install sshpass`
- Install collections:
  `ansible-galaxy collection install -r collections/requirements.yml -p collections`

## Usage

Run commands from this directory, through `uv run` so they use the synced venv (has `ansible-core` and `httpx` - the latter needed by the `ansibleguy.opnsense` modules, which run locally on the controller rather than over SSH - see the OPNsense section below):

Create a local variables file before running playbooks. Ansible loads this automatically from `group_vars`, so no export or wrapper script is needed:

```sh
cp inventories/homelab/group_vars/all/local.yml.example inventories/homelab/group_vars/all/local.yml
```

```sh
uv run ansible-playbook playbooks/bootstrap.yml
uv run ansible-playbook playbooks/proxmox.yml
uv run ansible-playbook playbooks/maintenance.yml
uv run ansible-playbook playbooks/health.yml
```

To run a playbook against a single host, use `--limit` with the inventory host name:

```sh
uv run ansible-playbook playbooks/bootstrap.yml --limit pve
uv run ansible-playbook playbooks/proxmox.yml --limit pve
uv run ansible-playbook playbooks/health.yml --limit pve
```

For Proxmox hosts, run `bootstrap.yml` first to create the OS admin user, then `proxmox.yml` to register that user in Proxmox and assign its ACL.

After bootstrap, Proxmox hosts connect as the managed `ansible` user with the configured SSH key. For a first-time bootstrap before that user exists, override the connection user at the command line:

```sh
uv run ansible-playbook playbooks/bootstrap.yml --limit pve -u root -e ansible_password='your-root-password'
```

If you'd rather not prefix every command, `source .venv/bin/activate` once per shell session instead.

The default inventory is configured in `ansible.cfg`.

## Adding Hosts

Add hosts to the relevant logical group in `inventories/homelab/hosts.yml`, then put reusable settings in `group_vars/all.yml` or the matching group file.

## Linting

`uv sync` also installs `ansible-lint` and `yamllint` (the `dev` dependency group). Run them the same way CI does:

```sh
uv run ansible-galaxy collection install -r collections/requirements.yml -p collections
uv run ansible-lint
uv run yamllint .
```

All role variables are prefixed with their defining role's name (`var-naming[no-role-prefix]`, enforced, no skip). Note `updates_reboot_timeout_seconds` (defined in `updates/defaults`) is also read directly by the separate `reboot` role - it's genuinely shared across two independent playbooks, not private to either, so `reboot`'s reference to it is intentional rather than a leftover.

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

`playbooks/proxmox.yml` also runs the `proxmox_vm_template` role, which downloads a cloud image and turns it into a Proxmox VM template (`qm importdisk` + a cloud-init drive + `qm template`) that OpenTofu can clone per VM. It's off by default; enable it with a `proxmox_vm_template_templates` list, one entry per OS:

```yaml
proxmox_vm_template_templates_manage: true
proxmox_vm_template_templates:
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
proxmox_lxc_template_templates_manage: true
proxmox_lxc_template_storage: local   # must have the vztmpl content type
proxmox_lxc_template_templates:
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

1. **Install OPNsense** on its own hardware and, via its console, assign interfaces and give each a static address (option 1, then option 2 in the console menu), using your own network's IP plan. These roles assume OPNsense is already reachable over HTTPS on its LAN address.
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

Only rules that need to actively *allow* something go here — OPNsense's default deny-all on every new interface already handles isolation (e.g. CAMERAS/IOT can't reach LAN or WAN) without any explicit block rules.

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

The `ansibleguy.opnsense` modules need the `httpx` Python package. `router`'s `ansible_connection: local` means those modules execute on the controller rather than over SSH - but local-connection interpreter auto-detection does **not** reliably resolve to whatever's running `ansible-playbook` (verified: it falls back to `/usr/bin/python3`, macOS's bare system Python, which doesn't have `httpx`). `hosts.yml` sets `ansible_python_interpreter: "{{ ansible_playbook_python }}"` for `router` specifically to force it - that magic variable *does* reliably hold the actual running interpreter, which is the `uv`-managed venv's Python as long as commands run via `uv run` (see Requirements above). No machine-specific hardcoded path needed, but `uv run` isn't optional for this host.

### Not yet automated

- **Interface assignment.** Renaming/describing a base physical interface (e.g. `OPT1` → `CAMERAS`) or setting its IPv4 address has no supported module in this collection — only virtual interface types (VLAN, bridge, LAGG, etc.) are covered. This stays a manual console/GUI step for now; not worth building on the collection's `raw`/unstable escape hatch for something this foundational to network connectivity.
- **Alternate Hostnames** (System → Settings → Administration). OPNsense's web GUI has built-in DNS rebind protection - it only trusts requests whose `Host` header is the router's IP or an explicitly allow-listed hostname, so visiting it via a new internal DNS name (e.g. `router.local.example.com`) shows a rebind-attack warning until that name is added here. No module in this collection covers this settings page (only `system.py`'s reboot/update/upgrade/audit *actions*, not general webgui settings). Left manual since it's only touched when OPNsense's own admin GUI gets a new DNS name - rare, not worth automating.

## Technitium DNS

`playbooks/technitium.yml` installs Technitium DNS Server (via its own official install script - no apt repo) on the VM `iac/opentofu/vm_technitium.tf` provisions at a static IP. It runs as its own VM rather than in k3s since DNS is foundational infrastructure that shouldn't depend on the cluster that will eventually depend on it.

Unlike OPNsense, Technitium's first-run bootstrap is fully automated - `technitium_install`'s tasks log in with its default `admin`/`admin` credentials (this only succeeds on a never-configured instance, which doubles as the idempotency check), change the password to `technitium_install_admin_password`, mint a non-expiring **API token**, and write it to `~/.technitium/ansible.env` (plain text, just the token) — same "credential lives outside the repo" pattern as `~/.opnsense/ansible.env` and `~/.proxmox/opentofu.env`. This means a full `tofu destroy`/`apply` cycle (which rebuilds this VM from scratch) needs no manual intervention.

### Registering DNS records

Most hosts now get a static IP, so their records are declared in `group_vars/all/dns_records.yml` (`technitium_dns_records`, matched by `name` — same list-of-dicts pattern as `traefik_install_reverse_proxy_sites`) and converged with:

```sh
ansible-playbook playbooks/dns_records.yml
```

For a genuinely one-off/ad-hoc record instead - e.g. something DHCP-assigned that isn't worth declaring - `playbooks/dns_record.yml` (singular) registers a single record directly:

```sh
ansible-playbook playbooks/dns_record.yml -e dns_name=gpu-box.local.example.com -e dns_ip=192.0.2.163
```

Nothing in `iac/opentofu/` currently calls this automatically via a provisioner - `vm_gpu_box.tf` used to (registering its then-DHCP address at creation time), but it moved to a static IP declared in `dns_records.yml` instead, same as `vm_technitium.tf` and the Traefik LXC. Kept around as a manual escape hatch, not dead code.

Both playbooks share `tasks/technitium_record.yml`, which calls Technitium's own REST API directly via `ansible.builtin.uri` — no external collection dependency (deliberately: the community options at the time were either a young/rough Terraform provider from a single maintainer, or an Ansible collection judged not worth the dependency for what's a ~30-line task). `/api/zones/records/add` with `overwrite=true` replaces the entire record set for that name/type, making a single API call idempotent by construction — no need to check for an existing record first. Auth is a plain `Authorization: Bearer <token>` header. Technitium always returns HTTP 200; a logical failure (bad token, invalid zone) only shows up in the JSON body's `status` field, which the playbook checks explicitly.

**`vm_technitium.tf` itself deliberately has no self-registration provisioner** — its own provisioner only runs `playbooks/technitium.yml` (install + bootstrap), not `dns_records.yml`. The token now exists automatically once that finishes, but Technitium's own DNS record still needs `ansible-playbook playbooks/dns_records.yml` run once, afterward, to register it.

## Traefik reverse proxy

`playbooks/traefik.yml` installs Traefik on the LXC container `iac/opentofu/lxc_traefik.tf` provisions. It fronts internal web UIs at clean `*.local.example.com`-style hostnames (see `local_domain`) with real Let's Encrypt certs via Cloudflare DNS-01 — this only requires Cloudflare to be authoritative for the zone, not for the hostname itself to be publicly reachable, so purely-internal names can still get valid, trusted certs. Proxied services are declared in `group_vars/all/traefik_install_reverse_proxy_sites.yml` (same list pattern as `technitium_dns_records`).

Two credentials needed before running the playbook, both kept outside the repo:

- **Cloudflare API token**, scoped to `Zone:DNS:Edit` on your domain's zone only (Cloudflare dashboard → My Profile → API Tokens → Create Token → "Edit zone DNS" template). Save it to `~/.cloudflare/ansible.env` (plain text, just the token) — same pattern as `~/.technitium/ansible.env`.
- **Dashboard login** (`traefik.<local_domain>`, behind HTTP basic auth): set `traefik_dashboard_user` and `traefik_dashboard_password_hash` in `local.yml`. Generate the hash with `openssl passwd -apr1` — never store the plaintext password anywhere in the repo.

## GPU box: Docker, NVIDIA, Dockge, Jellyfin, Ollama

`playbooks/gpu_services.yml` converges everything on the GPU VM `iac/opentofu/vm_gpu_box.tf` provisions (static IP, `hostpci0` passthrough via the `gpu0` resource mapping): Docker Engine, the NVIDIA driver + container toolkit, then three docker-compose stacks, in that order (each later role depends on the one before it):

```sh
ansible-playbook playbooks/gpu_services.yml
ansible-playbook playbooks/dns_records.yml
ansible-playbook playbooks/traefik.yml
```

### Docker (`docker_install`)

Installs Docker Engine + Compose plugin from Docker's official apt repo, pinned to exact versions and held afterward (`dpkg_selections`) so `playbooks/updates.yml`'s `apt upgrade: full` can't silently drift them - bump `docker_*_version` in `roles/docker_install/defaults/main.yml` deliberately, checking `https://download.docker.com/linux/ubuntu/dists/noble/stable/binary-amd64/Packages` for current versions. Also creates `docker_stacks_dir` (`/opt/stacks`, declared in `group_vars/gpu.yml`), where every compose-based service below gets deployed - one subdirectory per stack, matching Dockge's own expected layout.

### NVIDIA driver + container toolkit (`nvidia_driver_install`)

Installs the recommended driver via `ubuntu-drivers autoinstall`, rebooting only if a fresh driver actually got installed, then installs `nvidia-container-toolkit` and wires it into Docker's runtime. Runs after `docker_install` since the runtime-configure step needs a docker service to restart.

**Important gotcha, not just for this role but for every compose file below**: on this Docker version, the plain `--gpus all` flag (and the equivalent `deploy.resources.reservations.devices` compose syntax) resolves through Docker's CDI vendor lookup and fails with `Error response from daemon: AMD CDI spec not found` — even for an NVIDIA-only host. The fix is generating an NVIDIA CDI spec (`nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml`, this role's last install step) and requesting the GPU by its CDI-qualified name instead. Every compose file in this section uses:

```yaml
devices:
  - nvidia.com/gpu=all
```

not `--gpus`/`deploy.reservations.devices`. The role's own smoke test (`docker run --device nvidia.com/gpu=all ... nvidia-smi`) verifies this works at the end of the run.

### Dockge (`dockge_install`)

A lighter-weight alternative to Portainer - manages `docker-compose.yml` stacks directly rather than wrapping them in a heavier abstraction. Deployed to `{{ docker_stacks_dir }}/dockge`, bind-mounts `docker_stacks_dir` into itself at the same path so it can see/manage every stack including its own, port 5001, `dockge.<local_domain>` via Traefik.

Dockge's whole pitch is editing stacks *through its UI* - since Ansible owns these compose files (templated, git-tracked), treat Dockge as a dashboard/start-stop/log-viewer tool here, not a config editor. Edits made in its UI will get silently overwritten the next time the role runs.

### Jellyfin (`jellyfin_install`)

Media library lives on the NAS, not the VM's own disk - mounted read-only via NFS (`ansible.posix.mount`, `ro,_netdev,nofail`: Jellyfin only ever reads media, and a NAS hiccup at boot shouldn't hang the VM). Export path and mount point are `jellyfin_install_nas_export`/`jellyfin_install_nas_mount_point` in `roles/jellyfin_install/defaults/main.yml`; confirm the actual export with `showmount -e <nas-host>` before changing it. Host networking (Jellyfin's own recommendation, needed for LAN auto-discovery), GPU passed through via the CDI syntax above, `jellyfin.<local_domain>` via Traefik.

Hardware transcoding is pre-seeded, not clicked through the UI: the role templates `config/config/encoding.xml` (the file Dashboard → Playback → Transcoding itself writes to) with `HardwareAccelerationType=nvenc` and the codec lists, then restarts the container so it's picked up (Jellyfin only reads it at startup). Tuned for the GTX 1060 in `vm_gpu_box.tf` - Pascal does H.264/HEVC 8-bit both ways, HEVC 10-bit decode only, no AV1 at all - via `jellyfin_install_hardware_acceleration_type`/`jellyfin_install_hardware_decoding_codecs`/`jellyfin_install_allow_hevc_encoding`/`jellyfin_install_allow_av1_encoding` in `roles/jellyfin_install/defaults/main.yml`. Swap the GPU and these need revisiting.

One thing stays manual, inherently interactive and not worth scripting for a single-admin homelab:
1. **First-run setup wizard** - create the admin account, point the first library at `/media`.

### Ollama (`ollama_install`)

Deployed to `{{ docker_stacks_dir }}/ollama`, port 11434, models persisted at `./data` (survives container recreation), GPU via the same CDI syntax. Models to keep pulled are declared in `ollama_models` (`group_vars/gpu.yml`, same declared-list pattern as `technitium_dns_records`/`traefik_install_reverse_proxy_sites`) - the role waits for the API to come up, then `POST /api/pull` (`stream: false`, blocking) for each. Idempotent: Ollama checks blobs by digest against what's already in `./data`, so re-running only downloads what's actually missing, not a full re-fetch.

**No authentication on Ollama's API** - anything that can reach `ollama.<local_domain>` can pull models and run inference. Fine on a trusted LAN; don't put this on the public side of Cloudflare Tunnel (roadmap step 7) without an auth layer in front of it.

## k3s cluster: control-plane + 2 workers

`playbooks/k3s_cluster.yml` converges the k3s prod cluster `iac/opentofu/vm_k3s_prod.tf` provisions (static IPs, `300-302`). No Rancher/hub VM - a single cluster, k3s installed directly.

Tolkien theme, continuing `palantir`'s lead: **`gondor`** is the control-plane, **`rohan`**/**`shire`** are workers - same standalone-name convention as `palantir`/`technitium` (no `k3s-` prefix on the hostnames themselves; the `k3s` inventory group is what ties them together).

```sh
ansible-playbook playbooks/k3s_cluster.yml
ansible-playbook playbooks/dns_records.yml
```

### `k3s_install`

One role, two roles-within-the-role depending on group membership (`prod_control_plane` vs `prod_workers`, both children of the `kubernetes` group in `hosts.yml` - named generically so it stays accurate if a future second cluster uses a different distro):

- **Shared prereqs** on every node: swap disabled (`swapoff -a` + stripped from `/etc/fstab`), `overlay`/`br_netfilter` kernel modules loaded and persisted (`/etc/modules-load.d/k3s.conf`), and the sysctls k3s's networking needs (`net.ipv4.ip_forward`, `net.bridge.bridge-nf-call-iptables`/`ip6tables`) via `ansible.posix.sysctl`.
- **Install**, version-pinned (`k3s_version` in `group_vars/kubernetes.yml`) via the official `get.k3s.io` script, gated by the same "check installed version, only reinstall if it differs" idiom as `node_exporter_install` - `k3s --version`'s output compared against the pinned version rather than a separate marker file. `--disable traefik --disable servicelb` on the server - the existing standalone Traefik LXC stays the one ingress path for this fleet, not k3s's bundled ones.
- **Join token handoff, in-memory, no separate credential store**: the control-plane play slurps `/var/lib/rancher/k3s/server/node-token` and exposes it as a fact; the workers play (same `ansible-playbook` invocation, control-plane play runs first) reads it via `hostvars[groups['prod_control_plane'][0]]['k3s_install_node_token']` for `K3S_TOKEN`. `no_log: true` on the agent-install task so the token never lands in output. This only works within a single run - `--limit` on any one node's OpenTofu-triggered convergence always includes the control-plane host (e.g. `gondor:rohan`) so the token fact gets (re-)derived every time, even though installing it is a no-op after the first run.

**Kubeconfig**: not automated - pull it yourself once the control-plane is up:

```sh
ssh ansible@gondor.<local_domain> sudo cat /etc/rancher/k3s/k3s.yaml
```

Swap `127.0.0.1` in that file for the control-plane's real IP before using it from your own machine.

Node-exporter (fleet-wide metrics) and the usual `bootstrap`/`health`/`updates`/`maintenance` playbooks all include the `kubernetes` group already. Not yet added to `reboot.yml`/`shutdown.yml` (no drain/cordon logic).

### MetalLB (`metallb_install`)

`playbooks/metallb_install.yml`, run against `prod_control_plane` (`gondor`): `helm_install` first (shared role - version-pinned tarball + version-marker idiom, same as `node_exporter_install`), then `helm upgrade --install`s the `metallb/metallb` chart into `metallb-system`, then applies an `IPAddressPool`/`L2Advertisement` pair (L2/ARP mode - no BGP-speaking router here) built from `metallb_install_ip_range` (`group_vars/all/local.yml`, real LAN addresses, gitignored - never committed).

```sh
ansible-playbook playbooks/metallb_install.yml
```

This is what makes `type: LoadBalancer` Services actually get a real, stable LAN IP on bare metal instead of sitting in `Pending` forever - there's no cloud controller manager to provision one the way GKE/EKS/etc. would. Install this before `argocd_install` or the GitOps-managed ingress controller (`iac/argocd/apps/ingress-controller.yaml`), since both depend on it.

### Argo CD (`argocd_install`)

`playbooks/argocd_install.yml`, run against `prod_control_plane` (`gondor`): `helm_install` first, then `helm upgrade --install`s the `argo/argo-cd` chart into the `argocd` namespace, using `gondor`'s own `/etc/rancher/k3s/k3s.yaml` (`k3s_kubeconfig_path`, `group_vars/kubernetes.yml`) as `KUBECONFIG` - no external credential needed since it's managing the cluster it runs in ("in-cluster" destination). Argo CD stays Ansible-installed rather than self-managed via GitOps - it can't deploy itself before it exists, and self-management is a known foot-gun (a bad self-managed change can break the very tool that would fix it); this keeps it as a deliberate, debuggable "break glass" install.

```sh
ansible-playbook playbooks/argocd_install.yml
```

**Reachable at `argocd.<local_domain>`** through the existing Traefik LXC, same as every other service in this fleet - not port-forward. The Helm install sets `configs.params."server\.insecure"=true` (serves plain HTTP internally - the LXC already terminates real TLS at the edge) and the role applies a static `IngressRoute` (`files/argocd-ingressroute.yaml`) matching `HostRegexp(`^argocd\..+$`)` on the in-cluster Traefik ingress controller (see `iac/argocd/apps/ingress-controller.yaml`). `traefik_install_reverse_proxy_sites.yml` points Traefik at `http://{{ k8s_ingress_lb_ip }}` (the ingress controller's MetalLB-assigned IP) - same upstream homepage uses, disambiguated by `Host` header, not a per-service NodePort/IP anymore.

Login itself stays manual/interactive - the initial admin password:

```sh
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
```

### Sealed Secrets

Moved to GitOps (`iac/argocd/apps/sealed-secrets.yaml`) - no bootstrap dependency like Argo CD has, so there's no reason to keep it Ansible-managed. `kubeseal` encrypts a value client-side against the controller's public key, the encrypted `SealedSecret` is safe to commit, and only the in-cluster controller (private key never leaves the cluster) can decrypt it back into a real `Secret`. See `iac/argocd/homepage/README.md` for a worked example (the `homepage-domain` secret).

GitOps manifests live at `iac/argocd/` (own README there) - first workload deployed is `homepage` (see `iac/argocd/homepage/`).
