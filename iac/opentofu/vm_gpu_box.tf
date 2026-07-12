# Step 1 of docs/roadmap.md: a single VM cloned from the ubuntu-2404 template
# (proxmox_vm_template, vmid 9000), with the GTX 1060 passed through via the
# gpu0 resource mapping (proxmox_gpu_passthrough). Intended workloads:
# Jellyfin, Ollama, Docker/Portainer (added in a later step).

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
  name      = "ubuntu-2404-gpu-box"
  node_name = var.pve_node

  clone {
    vm_id = 9000
    # local-vmstore is plain LVM (not thin-provisioned), which only supports
    # full clones, not linked clones.
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
    cores = 4
  }

  memory {
    dedicated = 8192
  }

  disk {
    datastore_id = "local-vmstore"
    interface    = "scsi0"
    size         = 60
  }

  hostpci {
    device  = "hostpci0"
    mapping = "gpu0"
    pcie    = true
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
        address = "dhcp"
      }
    }
  }
}

output "gpu_box_ipv4_addresses" {
  description = "IP addresses reported by the QEMU guest agent once the VM has booted."
  value       = proxmox_virtual_environment_vm.gpu_box.ipv4_addresses
}
