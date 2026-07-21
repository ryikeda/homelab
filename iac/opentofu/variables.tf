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

variable "technitium_ip" {
  description = "Static IPv4 CIDR address for the Technitium DNS VM (see docs/network.md)."
  type        = string
}

variable "lan_gateway" {
  description = "Gateway address for the LAN network."
  type        = string
}

variable "local_domain" {
  description = "Internal-only DNS domain suffix for locally-registered records (see docs/network.md)."
  type        = string
}
