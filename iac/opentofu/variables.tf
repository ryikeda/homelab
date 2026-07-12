variable "pve_node" {
  description = "Proxmox node name VMs and containers are created on."
  type        = string
  default     = "pve"
}

variable "proxmox_insecure" {
  description = "Skip TLS certificate verification. Needed for Proxmox's default self-signed certificate; set false once a real certificate is installed."
  type        = bool
  default     = true
}
