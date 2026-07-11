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
