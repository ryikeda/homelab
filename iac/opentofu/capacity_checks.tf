# Surfaces real, live usage (not declared VM sizes - meaningless once
# local-vmstore is thin-provisioned, since declared size no longer equals
# actual consumption) at plan/apply time, instead of finding out from a red
# bar in the Proxmox UI after the fact.

data "proxmox_datastores" "pve" {
  node_name = var.pve_node
}

data "proxmox_virtual_environment_node" "pve" {
  node_name = var.pve_node
}

locals {
  vmstore_datastore = one([
    for ds in data.proxmox_datastores.pve.datastores : ds
    if ds.id == "local-vmstore"
  ])

  # Hard-block thresholds, stricter than the check-block warnings above -
  # referenced by every VM/container resource's lifecycle.precondition.
  # Applies to every apply that touches a resource, not just ones creating
  # new VMs - once past this line, Terraform refuses to apply anything
  # against those resources until it's resolved, which is a blunt but
  # deliberate forcing function.
  vmstore_capacity_ok = local.vmstore_datastore.space_used_fraction < 0.95
  vmstore_capacity_message = format(
    "local-vmstore is %.1f%% used (>= 95%%) - refusing to apply until space is freed or storage is added.",
    local.vmstore_datastore.space_used_fraction * 100
  )

  node_memory_ok = (
    data.proxmox_virtual_environment_node.pve.memory_available /
    data.proxmox_virtual_environment_node.pve.memory_total
  ) > 0.10
  node_memory_message = format(
    "%s only has %.1f%% memory free (<= 10%%) - refusing to apply until memory pressure eases.",
    var.pve_node,
    (data.proxmox_virtual_environment_node.pve.memory_available / data.proxmox_virtual_environment_node.pve.memory_total) * 100
  )
}

# check blocks warn (a visible diagnostic) without blocking the plan/apply -
# the 80% threshold you asked for. Real prevention (hard-fail, stop the
# apply) needs a lifecycle.precondition on each VM resource instead, which
# is more invasive (touches every vm_*.tf) - add that on top of this if a
# warning isn't enough once you've lived with it a while.

check "vmstore_capacity" {
  assert {
    condition = local.vmstore_datastore.space_used_fraction < 0.80
    error_message = format(
      "local-vmstore is %.1f%% used (>= 80%%) - free space or add storage before provisioning more.",
      local.vmstore_datastore.space_used_fraction * 100
    )
  }
}

check "node_memory_capacity" {
  assert {
    # memory_available already reflects real ballooned usage, not just the
    # sum of every VM's dedicated ceiling - a truer "room left" number.
    condition = (
      data.proxmox_virtual_environment_node.pve.memory_available /
      data.proxmox_virtual_environment_node.pve.memory_total
    ) > 0.20
    error_message = format(
      "%s only has %.1f%% memory free (<= 20%%) - reconsider before adding another VM.",
      var.pve_node,
      (data.proxmox_virtual_environment_node.pve.memory_available / data.proxmox_virtual_environment_node.pve.memory_total) * 100
    )
  }
}

# cpu_utilization is live load, not committed/allocated capacity - it's
# noisy (a briefly idle host passes even if over-committed on paper, a
# brief spike fails even with room to spare), so this is a much weaker
# signal than the checks above. Treat it as a loose sanity check, not a
# real capacity gate - if you want a real one, sum cpu.cores across every
# proxmox_virtual_environment_vm resource and compare against cpu_count
# instead, which requires maintaining that resource list by hand.
check "node_cpu_sanity" {
  assert {
    condition = data.proxmox_virtual_environment_node.pve.cpu_utilization < 0.80
    error_message = format(
      "%s's live CPU utilization is %.1f%% (>= 80%%) - this reflects current load, not committed capacity, so double-check before treating it as a hard signal.",
      var.pve_node,
      data.proxmox_virtual_environment_node.pve.cpu_utilization * 100
    )
  }
}
