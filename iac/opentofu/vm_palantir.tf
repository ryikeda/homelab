# Static IP, same reasoning as Technitium/Traefik - a monitoring box that
# depends on DHCP working at boot is a bad look for the thing watching
# whether the rest of the network is healthy.

resource "proxmox_virtual_environment_vm" "palantir" {
  name      = "palantir"
  node_name = var.pve_node
  vm_id = 104
  tags  = ["ubuntu-2404"]

  clone {
    vm_id = 9000
    # local-vmstore is plain LVM, which only supports full clones.
    full = true
  }

  cpu {
    cores = 2
    type  = "host"
  }

  memory {
    dedicated = 4096
    floating  = 1024
  }

  disk {
    datastore_id = "local-vmstore"
    interface    = "scsi0"
    # Prometheus's TSDB grows slowly for a handful of scrape targets, but
    # give it real room to run for years without an early resize.
    size = 32
  }

  agent {
    enabled = true
  }

  initialization {
    dns {
      domain  = var.local_domain
      servers = [var.lan_gateway]
    }

    vendor_data_file_id = proxmox_virtual_environment_file.gpu_box_vendor_data.id

    user_account {
      username = "ansible"
      keys     = [trimspace(file(pathexpand("~/.ssh/ansible.pub")))]
    }

    ip_config {
      ipv4 {
        address = var.palantir_ip
        gateway = var.lan_gateway
      }
    }
  }

  provisioner "local-exec" {
    working_dir = "${path.module}/../ansible"
    command     = <<-EOT
      set -e
      ip="${split("/", var.palantir_ip)[0]}"
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
      ansible-playbook playbooks/dns_records.yml
      ansible-playbook playbooks/bootstrap.yml --limit palantir
      ansible-playbook playbooks/monitoring.yml
    EOT

    # Don't force-recreate the VM just because one of these steps hiccuped -
    # re-run the relevant ansible-playbook command directly to retry instead
    # (each is idempotent). Same reasoning as vm_gpu_box.tf/vm_technitium.tf.
    on_failure = continue
  }
}

output "palantir_ipv4_addresses" {
  description = "IP addresses reported by the QEMU guest agent once the VM has booted."
  value       = proxmox_virtual_environment_vm.palantir.ipv4_addresses
}
