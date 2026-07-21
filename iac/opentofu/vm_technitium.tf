# Static IP, not DHCP - every other network's DNS resolution depends on this
# address being stable, so it shouldn't itself depend on DHCP working at boot.

resource "proxmox_virtual_environment_vm" "technitium" {
  name      = "technitium"
  node_name = var.pve_node

  clone {
    vm_id = 9000
    # local-vmstore is plain LVM, which only supports full clones.
    full = true
  }

  cpu {
    cores = 1
  }

  memory {
    dedicated = 1024
  }

  disk {
    datastore_id = "local-vmstore"
    interface    = "scsi0"
    # Disks can only grow, never shrink - the template's disk is already 20G.
    size = 20
  }

  agent {
    enabled = true
  }

  initialization {
    vendor_data_file_id = proxmox_virtual_environment_file.gpu_box_vendor_data.id

    user_account {
      username = "ansible"
      keys     = [trimspace(file(pathexpand("~/.ssh/ansible.pub")))]
    }

    ip_config {
      ipv4 {
        address = var.technitium_ip
        gateway = var.lan_gateway
      }
    }
  }

  provisioner "local-exec" {
    working_dir = "${path.module}/../ansible"
    command     = <<-EOT
      set -e
      ip="${split("/", var.technitium_ip)[0]}"
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
      # recreating this VM generates a new host key each time - clear any
      # stale entry and record the current one ourselves.
      ssh-keygen -R "$ip" 2>/dev/null || true
      ssh-keyscan -H "$ip" >> ~/.ssh/known_hosts 2>/dev/null
      ansible-playbook playbooks/technitium.yml --limit technitium
    EOT

    # Don't force-recreate the VM just because this step hiccuped - re-run
    # ansible-playbook directly to retry instead.
    on_failure = continue
  }

  # No self-registration provisioner here (unlike vm_gpu_box.tf): at this
  # VM's own creation time, Technitium has no API token yet. Its own record
  # is added manually once one exists.
}

output "technitium_ipv4_addresses" {
  description = "IP addresses reported by the QEMU guest agent once the VM has booted."
  value       = proxmox_virtual_environment_vm.technitium.ipv4_addresses
}
