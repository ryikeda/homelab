resource "proxmox_virtual_environment_file" "gpu_box_vendor_data" {
  content_type = "snippets"
  datastore_id = "local"
  node_name    = var.pve_node

  source_raw {
    file_name = "vendor-data-qemu-guest-agent.yaml"
    data      = file("${path.module}/files/vendor-data-qemu-guest-agent.yaml")
  }
}

resource "proxmox_virtual_environment_vm" "gpu_box" {
  name      = "gpu-box"
  node_name = var.pve_node
  vm_id     = 100
  tags      = ["ubuntu-2404"]

  clone {
    vm_id = 9000
    # local-vmstore is plain LVM, which only supports full clones.
    full = true
  }

  # Passthrough GPU is the only display device on this VM (vga=serial0 on the
  # template disables the emulated one), so SeaBIOS would try to run the
  # GTX 1060's legacy VBIOS option ROM at boot and hang. OVMF handles this
  # correctly, so override the template's firmware for this VM.
  bios = "ovmf"

  efi_disk {
    datastore_id = "local-vmstore"
    type         = "4m"
  }

  cpu {
    cores = 8
    type  = "host"
  }

  memory {
    dedicated = 24576
    # Enables the balloon device (range: floating..dedicated) so Proxmox
    # reports real in-guest usage instead of always showing the full
    # allocation as "used".
    floating = 4096
  }

  disk {
    datastore_id = "local-vmstore"
    interface    = "scsi0"
    size         = 150
  }

  hostpci {
    device  = "hostpci0"
    mapping = "gpu0"
    pcie    = true
  }

  agent {
    enabled = true
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
        address = var.gpu_box_ip
        gateway = var.lan_gateway
      }
    }
  }

  # Static IP now. Wait for SSH, refresh the
  # known_hosts entry (cloud-init regenerates the host key on every rebuild,
  # same as vm_technitium.tf), then converge this VM to a fully running
  # state in one shot: baseline access, DNS registration, and the
  # Docker/NVIDIA stack.
  provisioner "local-exec" {
    working_dir = "${path.module}/../ansible"
    command     = <<-EOT
      set -e
      ip="${split("/", var.gpu_box_ip)[0]}"
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
      ansible-playbook playbooks/bootstrap.yml --limit gpu-box
      ansible-playbook playbooks/dns_records.yml
      ansible-playbook playbooks/gpu_services.yml
    EOT
  }
}

output "gpu_box_ipv4_addresses" {
  description = "IP addresses reported by the QEMU guest agent once the VM has booted."
  value       = proxmox_virtual_environment_vm.gpu_box.ipv4_addresses
}
