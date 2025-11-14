locals {
  network_public_ipv4_enabled = var.talos_public_ipv4_enabled
  network_public_ipv6_enabled = var.talos_public_ipv6_enabled && var.talos_ipv6_enabled

  hcloud_network_id   = length(data.hcloud_network.this) > 0 ? data.hcloud_network.this[0].id : hcloud_network.this[0].id
  hcloud_network_zone = data.hcloud_location.this.network_zone

  # Network ranges
  network_ipv4_cidr                = length(data.hcloud_network.this) > 0 ? data.hcloud_network.this[0].ip_range : var.network_ipv4_cidr
  network_node_ipv4_cidr           = coalesce(var.network_node_ipv4_cidr, cidrsubnet(local.network_ipv4_cidr, 3, 2))
  network_service_ipv4_cidr        = coalesce(var.network_service_ipv4_cidr, cidrsubnet(local.network_ipv4_cidr, 3, 3))
  network_pod_ipv4_cidr            = coalesce(var.network_pod_ipv4_cidr, cidrsubnet(local.network_ipv4_cidr, 1, 1))
  network_native_routing_ipv4_cidr = coalesce(var.network_native_routing_ipv4_cidr, local.network_ipv4_cidr)

  network_node_ipv4_cidr_skip_first_subnet = cidrhost(local.network_ipv4_cidr, 0) == cidrhost(local.network_node_ipv4_cidr, 0)
  network_ipv4_gateway                     = cidrhost(local.network_ipv4_cidr, 1)

  # Subnet mask sizes
  network_pod_ipv4_subnet_mask_size = 24
  network_node_ipv4_subnet_mask_size = coalesce(
    var.network_node_ipv4_subnet_mask_size,
    32 - (local.network_pod_ipv4_subnet_mask_size - split("/", local.network_pod_ipv4_cidr)[1])
  )

  # Lists for control plane nodes
  control_plane_public_ipv4_list  = compact(distinct([for server in hcloud_server.control_plane : server.ipv4_address]))
  control_plane_public_ipv6_list  = compact(distinct([for server in hcloud_server.control_plane : server.ipv6_address]))
  control_plane_private_ipv4_list = compact(distinct([for server in hcloud_server.control_plane : tolist(server.network)[0].ip]))

  # Control plane VIPs
  control_plane_public_vip_ipv4  = local.control_plane_public_vip_ipv4_enabled ? data.hcloud_floating_ip.control_plane_ipv4[0].ip_address : null
  control_plane_private_vip_ipv4 = cidrhost(hcloud_network_subnet.control_plane.ip_range, -2)

  # Lists for worker nodes
  worker_public_ipv4_list  = compact(distinct([for server in hcloud_server.worker : server.ipv4_address]))
  worker_public_ipv6_list  = compact(distinct([for server in hcloud_server.worker : server.ipv6_address]))
  worker_private_ipv4_list = compact(distinct([for server in hcloud_server.worker : tolist(server.network)[0].ip]))

  # Lists for cluster autoscaler nodes
  cluster_autoscaler_public_ipv4_list  = compact(distinct([for server in local.talos_discovery_cluster_autoscaler : server.public_ipv4_address]))
  cluster_autoscaler_public_ipv6_list  = compact(distinct([for server in local.talos_discovery_cluster_autoscaler : server.public_ipv6_address]))
  cluster_autoscaler_private_ipv4_list = compact(distinct([for server in local.talos_discovery_cluster_autoscaler : server.private_ipv4_address]))

  # === STABLE SUBNET ALLOCATION ===

  # Base offset accounting for skip_first_subnet logic
  subnet_base_offset = 2 + (local.network_node_ipv4_cidr_skip_first_subnet ? 1 : 0)

  # Hetzner hard limit: 50 subnets per network
  # Theoretical max based on CIDR calculation
  theoretical_max_subnets = pow(2,
    local.network_node_ipv4_subnet_mask_size - split("/", local.network_node_ipv4_cidr)[1]
  )

  # Use minimum of theoretical and Hetzner limit
  max_node_subnets = min(local.theoretical_max_subnets, 50)

  # Reserved: Control Plane + Load Balancer + 1 backup slot = 3
  # Available for workers + autoscalers: 50 - 3 = 47
  available_worker_autoscaler_slots = local.max_node_subnets - local.subnet_base_offset - 1

  # Scenario-based allocation
  worker_range_start = local.subnet_base_offset
  worker_range_size = var.cluster_autoscaler_dedicated_subnets_enabled ? 23 : 46

  autoscaler_range_start = var.cluster_autoscaler_dedicated_subnets_enabled ?
    (local.worker_range_start + local.worker_range_size) : 49
  autoscaler_range_size = var.cluster_autoscaler_dedicated_subnets_enabled ? 23 : 1

  # === WORKER SUBNET SLOT ALLOCATION ===

  # Separate explicit from auto-assigned
  workers_explicit = [for np in var.worker_nodepools : np if np.subnet_index != null]
  workers_auto = [for np in var.worker_nodepools : np if np.subnet_index == null]

  # Explicit assignments (user-provided indices are relative to worker range)
  worker_explicit_slots = {
    for np in local.workers_explicit :
    np.name => local.worker_range_start + np.subnet_index
  }

  # Auto assignments via hash (hash to worker range)
  worker_auto_slots = {
    for np in local.workers_auto :
    np.name => local.worker_range_start + (
      parseint(substr(md5(np.name), 0, 8), 16) % local.worker_range_size
    )
  }

  # Merge explicit and auto
  worker_subnet_slots = merge(local.worker_explicit_slots, local.worker_auto_slots)

  # === AUTOSCALER SUBNET SLOT ALLOCATION (only if dedicated enabled) ===

  autoscaler_explicit = var.cluster_autoscaler_dedicated_subnets_enabled ? [
    for np in var.cluster_autoscaler_nodepools : np if np.subnet_index != null
  ] : []

  autoscaler_auto = var.cluster_autoscaler_dedicated_subnets_enabled ? [
    for np in var.cluster_autoscaler_nodepools : np if np.subnet_index == null
  ] : []

  autoscaler_explicit_slots = {
    for np in local.autoscaler_explicit :
    np.name => local.autoscaler_range_start + np.subnet_index
  }

  autoscaler_auto_slots = {
    for np in local.autoscaler_auto :
    np.name => local.autoscaler_range_start + (
      parseint(substr(md5(np.name), 0, 8), 16) % local.autoscaler_range_size
    )
  }

  autoscaler_subnet_slots = merge(local.autoscaler_explicit_slots, local.autoscaler_auto_slots)

  # === COLLISION DETECTION ===

  # Workers
  worker_explicit_used = toset(values(local.worker_explicit_slots))
  worker_auto_values = values(local.worker_auto_slots)
  worker_all_slots = values(local.worker_subnet_slots)

  worker_collision_with_explicit = length([
    for slot in local.worker_auto_values : slot
    if contains(local.worker_explicit_used, slot)
  ]) > 0

  worker_collision_among_auto = length(local.worker_auto_values) != length(distinct(local.worker_auto_values))

  # Calculate free worker slots for helpful error messages
  worker_free_slots = [
    for i in range(local.worker_range_size) :
    i if !contains(local.worker_all_slots, local.worker_range_start + i)
  ]

  # Autoscalers (only if dedicated enabled)
  autoscaler_explicit_used = toset(values(local.autoscaler_explicit_slots))
  autoscaler_auto_values = values(local.autoscaler_auto_slots)
  autoscaler_all_slots = values(local.autoscaler_subnet_slots)

  autoscaler_collision_with_explicit = var.cluster_autoscaler_dedicated_subnets_enabled && length([
    for slot in local.autoscaler_auto_values : slot
    if contains(local.autoscaler_explicit_used, slot)
  ]) > 0

  autoscaler_collision_among_auto = var.cluster_autoscaler_dedicated_subnets_enabled &&
    length(local.autoscaler_auto_values) != length(distinct(local.autoscaler_auto_values))

  autoscaler_free_slots = var.cluster_autoscaler_dedicated_subnets_enabled ? [
    for i in range(local.autoscaler_range_size) :
    i if !contains(local.autoscaler_all_slots, local.autoscaler_range_start + i)
  ] : []
}

data "hcloud_location" "this" {
  name = local.control_plane_nodepools[0].location
}

data "hcloud_network" "this" {
  count = var.hcloud_network != null || var.hcloud_network_id != null ? 1 : 0

  id = var.hcloud_network != null ? var.hcloud_network.id : var.hcloud_network_id
}

resource "hcloud_network" "this" {
  count = length(data.hcloud_network.this) > 0 ? 0 : 1

  name              = var.cluster_name
  ip_range          = local.network_ipv4_cidr
  delete_protection = var.cluster_delete_protection

  labels = {
    cluster = var.cluster_name
  }
}

resource "hcloud_network_subnet" "control_plane" {
  network_id   = local.hcloud_network_id
  type         = "cloud"
  network_zone = local.hcloud_network_zone

  ip_range = cidrsubnet(
    local.network_node_ipv4_cidr,
    local.network_node_ipv4_subnet_mask_size - split("/", local.network_node_ipv4_cidr)[1],
    0 + (local.network_node_ipv4_cidr_skip_first_subnet ? 1 : 0)
  )
}

resource "hcloud_network_subnet" "load_balancer" {
  network_id   = local.hcloud_network_id
  type         = "cloud"
  network_zone = local.hcloud_network_zone

  ip_range = cidrsubnet(
    local.network_node_ipv4_cidr,
    local.network_node_ipv4_subnet_mask_size - split("/", local.network_node_ipv4_cidr)[1],
    1 + (local.network_node_ipv4_cidr_skip_first_subnet ? 1 : 0)
  )
}

resource "hcloud_network_subnet" "worker" {
  for_each = { for np in local.worker_nodepools : np.name => np }

  network_id   = local.hcloud_network_id
  type         = "cloud"
  network_zone = local.hcloud_network_zone

  # Use stable slot assignment instead of array index
  ip_range = cidrsubnet(
    local.network_node_ipv4_cidr,
    local.network_node_ipv4_subnet_mask_size - split("/", local.network_node_ipv4_cidr)[1],
    local.worker_subnet_slots[each.key]
  )
}

# Autoscaler: Shared subnet (legacy behavior, slot 49)
resource "hcloud_network_subnet" "autoscaler_shared" {
  count = var.cluster_autoscaler_dedicated_subnets_enabled ? 0 : 1

  network_id   = local.hcloud_network_id
  type         = "cloud"
  network_zone = local.hcloud_network_zone

  # Always use slot 49 for shared autoscaler subnet
  ip_range = cidrsubnet(
    local.network_node_ipv4_cidr,
    local.network_node_ipv4_subnet_mask_size - split("/", local.network_node_ipv4_cidr)[1],
    49
  )

  depends_on = [
    hcloud_network_subnet.control_plane,
    hcloud_network_subnet.load_balancer,
    hcloud_network_subnet.worker
  ]
}

# Autoscaler: Dedicated subnets per pool (new behavior, slots 25-47)
resource "hcloud_network_subnet" "autoscaler_dedicated" {
  for_each = var.cluster_autoscaler_dedicated_subnets_enabled ? {
    for np in local.cluster_autoscaler_nodepools : np.name => np
  } : {}

  network_id   = local.hcloud_network_id
  type         = "cloud"
  network_zone = local.hcloud_network_zone

  # Use stable slot assignment
  ip_range = cidrsubnet(
    local.network_node_ipv4_cidr,
    local.network_node_ipv4_subnet_mask_size - split("/", local.network_node_ipv4_cidr)[1],
    local.autoscaler_subnet_slots[each.key]
  )

  depends_on = [
    hcloud_network_subnet.control_plane,
    hcloud_network_subnet.load_balancer,
    hcloud_network_subnet.worker
  ]
}

# === SUBNET ALLOCATION VALIDATION ===

resource "terraform_data" "validate_worker_subnets" {
  lifecycle {
    precondition {
      condition     = !local.worker_collision_with_explicit
      error_message = <<-EOT
        Worker subnet collision detected! Auto-assigned nodepool conflicts with explicit subnet_index.

        Conflicting nodepools: ${jsonencode([
          for np in local.workers_auto :
          np.name if contains(local.worker_explicit_used, local.worker_auto_slots[np.name])
        ])}

        Available free slots (relative indices): ${jsonencode(local.worker_free_slots)}

        Fix: Set explicit subnet_index (0-${local.worker_range_size - 1}) for one of the conflicting nodepools.
      EOT
    }

    precondition {
      condition     = !local.worker_collision_among_auto
      error_message = <<-EOT
        Worker subnet collision detected among auto-assigned nodepools!

        Current auto-assignments: ${jsonencode(local.worker_auto_slots)}

        Available free slots (relative indices): ${jsonencode(local.worker_free_slots)}

        Fix: Set explicit subnet_index for one of the colliding nodepools.
        Example:
          worker_nodepools = [
            { name = "conflicting-pool", subnet_index = ${length(local.worker_free_slots) > 0 ? local.worker_free_slots[0] : 0}, ... },
          ]
      EOT
    }

    precondition {
      condition     = length(var.worker_nodepools) <= local.worker_range_size
      error_message = <<-EOT
        Too many worker nodepools! Maximum allowed: ${local.worker_range_size}
        Current: ${length(var.worker_nodepools)}

        ${var.cluster_autoscaler_dedicated_subnets_enabled ?
          "With dedicated autoscaler subnets enabled, worker pools are limited to 23 slots." :
          "With shared autoscaler subnet (default), worker pools are limited to 46 slots."}
      EOT
    }
  }
}

resource "terraform_data" "validate_autoscaler_subnets" {
  count = var.cluster_autoscaler_dedicated_subnets_enabled ? 1 : 0

  lifecycle {
    precondition {
      condition     = !local.autoscaler_collision_with_explicit
      error_message = <<-EOT
        Autoscaler subnet collision detected! Auto-assigned nodepool conflicts with explicit subnet_index.

        Conflicting nodepools: ${jsonencode([
          for np in local.autoscaler_auto :
          np.name if contains(local.autoscaler_explicit_used, local.autoscaler_auto_slots[np.name])
        ])}

        Available free slots (relative indices): ${jsonencode(local.autoscaler_free_slots)}

        Fix: Set explicit subnet_index (0-${local.autoscaler_range_size - 1}) for one of the conflicting nodepools.
      EOT
    }

    precondition {
      condition     = !local.autoscaler_collision_among_auto
      error_message = <<-EOT
        Autoscaler subnet collision detected among auto-assigned nodepools!

        Current auto-assignments: ${jsonencode(local.autoscaler_auto_slots)}

        Available free slots (relative indices): ${jsonencode(local.autoscaler_free_slots)}

        Fix: Set explicit subnet_index for one of the colliding nodepools.
        Example:
          cluster_autoscaler_nodepools = [
            { name = "conflicting-pool", subnet_index = ${length(local.autoscaler_free_slots) > 0 ? local.autoscaler_free_slots[0] : 0}, ... },
          ]
      EOT
    }

    precondition {
      condition     = length(var.cluster_autoscaler_nodepools) <= local.autoscaler_range_size
      error_message = <<-EOT
        Too many autoscaler nodepools! Maximum allowed: ${local.autoscaler_range_size}
        Current: ${length(var.cluster_autoscaler_nodepools)}

        With dedicated autoscaler subnets enabled, autoscaler pools are limited to 23 slots.
      EOT
    }
  }
}
