# Static IP, same reasoning as Technitium/Traefik/Palantir - a storage
# box holding the DB/bucket data other services depend on shouldn't
# itself depend on DHCP working at boot.
#
# Deliberately its own VM, not in the k3s cluster - see
# docs/k3s-cluster-plan.md Phase 3/database_services_install role. Tagged
# "storage" (alongside every other VM's "ubuntu-2404" tag) for
# at-a-glance role identification in the Proxmox UI.

resource "proxmox_virtual_environment_vm" "rivendell" {
  name      = "rivendell"
  node_name = var.pve_node
  vm_id     = 106
  tags      = ["ubuntu-2404", "storage"]

  clone {
    vm_id = 9000
    # local-vmstore is plain LVM, which only supports full clones.
    full = true
  }

  cpu {
    cores = 4
    type  = "host"
  }

  memory {
    dedicated = 8192
    floating  = 2048
  }

  disk {
    datastore_id = "local-vmstore"
    interface    = "scsi0"
    # Postgres/MongoDB/SeaweedFS all live here - generous headroom for
    # SeaweedFS's actual object data specifically. Resize later if needed.
    size = 100
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
        address = var.rivendell_ip
        gateway = var.lan_gateway
      }
    }
  }

  provisioner "local-exec" {
    working_dir = "${path.module}/../ansible"
    command     = <<-EOT
      set -e
      ip="${split("/", var.rivendell_ip)[0]}"
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
      ansible-playbook playbooks/bootstrap.yml --limit rivendell
      ansible-playbook playbooks/database_services.yml
    EOT

    # Don't force-recreate the VM just because one of these steps hiccuped -
    # re-run the relevant ansible-playbook command directly to retry instead
    # (each is idempotent). Same reasoning as vm_gpu_box.tf/vm_technitium.tf.
    on_failure = continue
  }
}

output "rivendell_ipv4_addresses" {
  description = "IP addresses reported by the QEMU guest agent once the VM has booted."
  value       = proxmox_virtual_environment_vm.rivendell.ipv4_addresses
}
