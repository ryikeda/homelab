data "proxmox_version" "this" {}

output "proxmox_version" {
  description = "Confirms the provider can authenticate to Proxmox. Remove once real resources exist here."
  value       = data.proxmox_version.this.version
}
