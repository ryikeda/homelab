provider "proxmox" {
  # endpoint and api_token come from the PROXMOX_VE_ENDPOINT / PROXMOX_VE_API_TOKEN
  # environment variables (see README.md) rather than being set here, so the
  # opentofu@pve token never needs to touch a file in this repo.
  insecure = var.proxmox_insecure

  # Some operations (e.g. uploading 'snippets' content, which has no API
  # upload endpoint) fall back to SSH. Reuses the same 'ansible' identity
  # Ansible itself connects as; it already has passwordless sudo, which the
  # provider requires for a non-root SSH user.
  ssh {
    agent       = false
    username    = "ansible"
    private_key = file(pathexpand("~/.ssh/ansible"))
  }
}
