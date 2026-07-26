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

variable "traefik_ip" {
  description = "Static IPv4 CIDR address for the Traefik reverse proxy LXC container (see docs/network.md)."
  type        = string
}

variable "gpu_box_ip" {
  description = "Static IPv4 CIDR address for the GPU workload VM (see docs/network.md)."
  type        = string
}

variable "palantir_ip" {
  description = "Static IPv4 CIDR address for the Palantir monitoring VM (Prometheus + Grafana, see docs/network.md)."
  type        = string
}

variable "rivendell_ip" {
  description = "Static IPv4 CIDR address for the Rivendell storage VM (Postgres/MongoDB/SeaweedFS/CloudBeaver, see docs/network.md)."
  type        = string
}

variable "portainer_ip" {
  description = "Static IPv4 CIDR address for the Portainer LXC container (see docs/network.md)."
  type        = string
}

variable "gondor_ip" {
  description = "Static IPv4 CIDR address for the k3s control-plane VM (see docs/k3s-cluster-plan.md)."
  type        = string
}

variable "rohan_ip" {
  description = "Static IPv4 CIDR address for the k3s worker VM 'rohan' (see docs/k3s-cluster-plan.md)."
  type        = string
}

variable "shire_ip" {
  description = "Static IPv4 CIDR address for the k3s worker VM 'shire' (see docs/k3s-cluster-plan.md)."
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
