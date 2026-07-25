resource "proxmox_virtual_environment_container" "portainer" {
  node_name = var.pve_node
  vm_id = 105
  tags  = ["ubuntu-2404" ]

  operating_system {
    template_file_id = "local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst"
    type             = "ubuntu"
  }

  unprivileged = true
  started      = true

  # Docker needs to run inside this container - nesting is the
  # unprivileged-LXC feature that makes that work on Proxmox. keyctl would
  # help too but changing it requires root@pam (opentofu@pve is deliberately
  # scoped to a restricted Terraform role, see proxmox_opentofu_user) -
  # nesting alone is enough for plain Docker Engine use.
  features {
    nesting = true
  }

  cpu {
    cores = 1
  }

  memory {
    dedicated = 1024
  }

  disk {
    datastore_id = "local-vmstore"
    size = 8
  }

  network_interface {
    name   = "eth0"
    bridge = "vmbr0"
  }

  initialization {
    dns {
      domain  = var.local_domain
      servers = [var.lan_gateway]
    }

    hostname = "portainer"

    user_account {
      keys = [trimspace(file(pathexpand("~/.ssh/ansible.pub")))]
    }

    ip_config {
      ipv4 {
        address = var.portainer_ip
        gateway = var.lan_gateway
      }
    }
  }

  provisioner "local-exec" {
    working_dir = "${path.module}/../ansible"
    command     = <<-EOT
      set -e
      ip="${split("/", var.portainer_ip)[0]}"
      elapsed=0
      until nc -z -w 2 "$ip" 22 2>/dev/null; do
        if [ "$elapsed" -ge 300 ]; then
          echo "Timed out waiting for SSH on $ip" >&2
          exit 1
        fi
        sleep 5
        elapsed=$((elapsed + 5))
      done
      ssh-keygen -R "$ip" 2>/dev/null || true
      ssh-keyscan -H "$ip" >> ~/.ssh/known_hosts 2>/dev/null
      # -e ansible_user=root, not -u root - see lxc_traefik.tf for why.
      ansible-playbook playbooks/bootstrap.yml --limit portainer -e ansible_user=root
      ansible-playbook playbooks/portainer.yml --limit portainer
    EOT
    on_failure = continue
  }
}

output "portainer_ipv4_address" {
  description = "Static LAN address configured for the Portainer container."
  value       = var.portainer_ip
}
