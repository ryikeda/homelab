
resource "proxmox_virtual_environment_vm" "gondor" {
  name      = "gondor"
  node_name = var.pve_node
  vm_id = 300
  tags  = ["k8s", "ubuntu-2404"]

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
    # Enables the balloon device (range: floating..dedicated) so Proxmox
    # reports real in-guest usage instead of always showing the full
    # allocation as "used".
    floating = 1024
  }

  disk {
    datastore_id = "local-vmstore"
    interface    = "scsi0"
    size         = 20
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
        address = var.gondor_ip
        gateway = var.lan_gateway
      }
    }
  }

  provisioner "local-exec" {
    working_dir = "${path.module}/../ansible"
    command     = <<-EOT
      set -e
      ip="${split("/", var.gondor_ip)[0]}"
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
      ansible-playbook playbooks/bootstrap.yml --limit gondor
      ansible-playbook playbooks/dns_records.yml
      ansible-playbook playbooks/k3s_cluster.yml --limit gondor
    EOT

    # Don't force-recreate the VM just because one of these steps hiccuped -
    # re-run the relevant ansible-playbook command directly to retry instead
    # (each is idempotent). Same reasoning as vm_gpu_box.tf/vm_technitium.tf.
    on_failure = continue
  }
}

resource "proxmox_virtual_environment_vm" "rohan" {
  name      = "rohan"
  node_name = var.pve_node
  vm_id = 301
  tags  = ["k8s", "ubuntu-2404"]

  depends_on = [proxmox_virtual_environment_vm.gondor]

  clone {
    vm_id = 9000
    full  = true
  }

  cpu {
    cores = 2
    type  = "host"
  }

  memory {
    dedicated = 8192
    floating  = 2048
  }

  disk {
    datastore_id = "local-vmstore"
    interface    = "scsi0"
    size         = 40
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
        address = var.rohan_ip
        gateway = var.lan_gateway
      }
    }
  }

  provisioner "local-exec" {
    working_dir = "${path.module}/../ansible"
    command     = <<-EOT
      set -e
      ip="${split("/", var.rohan_ip)[0]}"
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
      ansible-playbook playbooks/bootstrap.yml --limit rohan
      ansible-playbook playbooks/dns_records.yml
      ansible-playbook playbooks/k3s_cluster.yml --limit gondor:rohan
    EOT

    on_failure = continue
  }
}

resource "proxmox_virtual_environment_vm" "shire" {
  name      = "shire"
  node_name = var.pve_node
  vm_id = 302
  tags  = ["k8s", "ubuntu-2404"]

  depends_on = [proxmox_virtual_environment_vm.gondor]

  clone {
    vm_id = 9000
    full  = true
  }

  cpu {
    cores = 2
    type  = "host"
  }

  memory {
    dedicated = 8192
    floating  = 2048
  }

  disk {
    datastore_id = "local-vmstore"
    interface    = "scsi0"
    size         = 40
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
        address = var.shire_ip
        gateway = var.lan_gateway
      }
    }
  }

  provisioner "local-exec" {
    working_dir = "${path.module}/../ansible"
    command     = <<-EOT
      set -e
      ip="${split("/", var.shire_ip)[0]}"
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
      ansible-playbook playbooks/bootstrap.yml --limit shire
      ansible-playbook playbooks/dns_records.yml
      ansible-playbook playbooks/k3s_cluster.yml --limit gondor:shire
    EOT

    on_failure = continue
  }
}

output "gondor_ipv4_addresses" {
  description = "IP addresses reported by the QEMU guest agent once the VM has booted."
  value       = proxmox_virtual_environment_vm.gondor.ipv4_addresses
}

output "rohan_ipv4_addresses" {
  description = "IP addresses reported by the QEMU guest agent once the VM has booted."
  value       = proxmox_virtual_environment_vm.rohan.ipv4_addresses
}

output "shire_ipv4_addresses" {
  description = "IP addresses reported by the QEMU guest agent once the VM has booted."
  value       = proxmox_virtual_environment_vm.shire.ipv4_addresses
}
