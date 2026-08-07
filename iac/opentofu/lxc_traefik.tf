resource "proxmox_virtual_environment_container" "traefik" {
  node_name = var.pve_node
  vm_id     = 103
  tags      = ["ubuntu-2404"]

  operating_system {
    template_file_id = "local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst"
    type             = "ubuntu"
  }

  unprivileged = true
  started      = true

  cpu {
    cores = 1
  }

  memory {
    dedicated = 512
  }

  disk {
    datastore_id = "local-vmstore"
    size         = 4
  }

  lifecycle {
    precondition {
      condition     = local.vmstore_capacity_ok
      error_message = local.vmstore_capacity_message
    }
    precondition {
      condition     = local.node_memory_ok
      error_message = local.node_memory_message
    }
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

    hostname = "traefik"

    user_account {
      keys = [trimspace(file(pathexpand("~/.ssh/ansible.pub")))]
    }

    ip_config {
      ipv4 {
        address = var.traefik_ip
        gateway = var.lan_gateway
      }
    }
  }

  provisioner "local-exec" {
    working_dir = "${path.module}/../ansible"
    command     = <<-EOT
      set -e
      ip="${split("/", var.traefik_ip)[0]}"
      elapsed=0
      until nc -z -w 2 "$ip" 22 2>/dev/null; do
        if [ "$elapsed" -ge 300 ]; then
          echo "Timed out waiting for SSH on $ip" >&2
          exit 1
        fi
        sleep 5
        elapsed=$((elapsed + 5))
      done
      # ansible.cfg's host_key_checking can't prompt non-interactively, and
      # recreating this container generates a new host key each time - clear
      # any stale entry and record the current one ourselves.
      ssh-keygen -R "$ip" 2>/dev/null || true
      ssh-keyscan -H "$ip" >> ~/.ssh/known_hosts 2>/dev/null
      # -e ansible_user=root, not -u root: inventory-set connection vars
      # (group_vars/reverse_proxy.yml sets ansible_user for post-bootstrap
      # runs) take precedence over the CLI -u flag, so -u alone gets
      # silently overridden. Extra-vars are the one thing that reliably wins.
      ansible-playbook playbooks/bootstrap.yml --limit traefik -e ansible_user=root
      ansible-playbook playbooks/traefik.yml --limit traefik
    EOT
  }
}

output "traefik_ipv4_address" {
  description = "Static LAN address configured for the Traefik container."
  value       = var.traefik_ip
}
