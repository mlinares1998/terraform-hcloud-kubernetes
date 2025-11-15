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

  # Subnet allocation schema (when skip_first_subnet = false):
  # Slot 0: Control Plane
  # Slot 1: Load Balancer
  # Slot 2: Reserved (alignment)
  # Slots 3-47: Manual assignment pool (45 slots, indices 0-44)
  # Slot 48: Worker shared subnet
  # Slot 49: Autoscaler shared subnet
  #
  # When skip_first_subnet = true, all slots shift +1:
  # Slot 0: Skipped
  # Slot 1: Control Plane
  # Slot 2: Load Balancer
  # Slot 3: Reserved (alignment)
  # Slots 4-47: Manual assignment pool (44 slots, indices 0-43)
  # Slot 48: Worker shared subnet
  # Slot 49: Autoscaler shared subnet

  # Base offset accounting for skip_first_subnet logic
  subnet_base_offset = 2 + (local.network_node_ipv4_cidr_skip_first_subnet ? 1 : 0)

  # Manual assignment pool adjusts based on skip_first_subnet
  # skip=false: slots 3-47 (45 slots), skip=true: slots 4-47 (44 slots)
  manual_pool_start = local.subnet_base_offset + 1  # After Control Plane and Load Balancer
  manual_pool_size  = 45 - (local.network_node_ipv4_cidr_skip_first_subnet ? 1 : 0)

  # Shared subnet slots
  worker_shared_slot     = manual_pool_start + manual_pool_size      # Slot 48
  autoscaler_shared_slot = manual_pool_start + manual_pool_size + 1  # Slot 49

  # === WORKER SUBNET ALLOCATION ===

  # Separate workers with explicit subnet_index from those using shared subnet
  workers_manual = [for np in var.worker_nodepools : np if np.subnet_index != null]
  workers_shared = [for np in var.worker_nodepools : np if np.subnet_index == null]

  # Manual worker assignments (subnet_index is relative to manual pool: 0-44)
  worker_manual_slots = {
    for np in local.workers_manual :
    np.name => local.manual_pool_start + np.subnet_index
  }

  # === AUTOSCALER SUBNET ALLOCATION ===

  # Separate autoscalers with explicit subnet_index from those using shared subnet
  autoscalers_manual = [for np in var.cluster_autoscaler_nodepools : np if np.subnet_index != null]
  autoscalers_shared = [for np in var.cluster_autoscaler_nodepools : np if np.subnet_index == null]

  # Manual autoscaler assignments (subnet_index is relative to manual pool: 0-44)
  autoscaler_manual_slots = {
    for np in local.autoscalers_manual :
    np.name => local.manual_pool_start + np.subnet_index
  }

  # === COLLISION DETECTION ===

  # Collect all manually assigned slot indices
  all_manual_slots        = concat(values(local.worker_manual_slots), values(local.autoscaler_manual_slots))
  all_manual_slot_indices = [for slot in local.all_manual_slots : slot - local.manual_pool_start]

  # Check for collisions between workers and autoscalers
  manual_assignment_collision = length(local.all_manual_slots) != length(distinct(local.all_manual_slots))

  # Calculate free manual slots for helpful error messages
  manual_free_slots = [
    for i in range(local.manual_pool_size) :
    i if !contains(local.all_manual_slot_indices, i)
  ]
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

# Worker subnets: Manual assignments (dedicated subnet per pool with explicit subnet_index)
resource "hcloud_network_subnet" "worker_manual" {
  for_each = { for np in local.workers_manual : np.name => np }

  network_id   = local.hcloud_network_id
  type         = "cloud"
  network_zone = local.hcloud_network_zone

  ip_range = cidrsubnet(
    local.network_node_ipv4_cidr,
    local.network_node_ipv4_subnet_mask_size - split("/", local.network_node_ipv4_cidr)[1],
    local.worker_manual_slots[each.key]
  )
}

# Worker subnet: Shared pool (for all workers without explicit subnet_index)
resource "hcloud_network_subnet" "worker_shared" {
  count = length(local.workers_shared) > 0 ? 1 : 0

  network_id   = local.hcloud_network_id
  type         = "cloud"
  network_zone = local.hcloud_network_zone

  ip_range = cidrsubnet(
    local.network_node_ipv4_cidr,
    local.network_node_ipv4_subnet_mask_size - split("/", local.network_node_ipv4_cidr)[1],
    local.worker_shared_slot
  )

  depends_on = [
    hcloud_network_subnet.control_plane,
    hcloud_network_subnet.load_balancer,
    hcloud_network_subnet.worker_manual
  ]
}

# Autoscaler subnets: Manual assignments (dedicated subnet per pool with explicit subnet_index)
resource "hcloud_network_subnet" "autoscaler_manual" {
  for_each = { for np in local.autoscalers_manual : np.name => np }

  network_id   = local.hcloud_network_id
  type         = "cloud"
  network_zone = local.hcloud_network_zone

  ip_range = cidrsubnet(
    local.network_node_ipv4_cidr,
    local.network_node_ipv4_subnet_mask_size - split("/", local.network_node_ipv4_cidr)[1],
    local.autoscaler_manual_slots[each.key]
  )

  depends_on = [
    hcloud_network_subnet.control_plane,
    hcloud_network_subnet.load_balancer,
    hcloud_network_subnet.worker_manual,
    hcloud_network_subnet.worker_shared
  ]
}

# Autoscaler subnet: Shared pool (for all autoscalers without explicit subnet_index)
resource "hcloud_network_subnet" "autoscaler_shared" {
  count = length(local.autoscalers_shared) > 0 || !local.cluster_autoscaler_enabled ? 1 : 0

  network_id   = local.hcloud_network_id
  type         = "cloud"
  network_zone = local.hcloud_network_zone

  ip_range = cidrsubnet(
    local.network_node_ipv4_cidr,
    local.network_node_ipv4_subnet_mask_size - split("/", local.network_node_ipv4_cidr)[1],
    local.autoscaler_shared_slot
  )

  depends_on = [
    hcloud_network_subnet.control_plane,
    hcloud_network_subnet.load_balancer,
    hcloud_network_subnet.worker_manual,
    hcloud_network_subnet.worker_shared,
    hcloud_network_subnet.autoscaler_manual
  ]
}

# === SUBNET ALLOCATION VALIDATION ===
# Note: Basic range validation (0-44) is performed at variable level for early detection.
# Context-aware validations (exact range based on skip_first_subnet, collision, total count) performed here.

resource "terraform_data" "validate_subnet_allocation" {
  lifecycle {
    # Validate worker subnet_index is within context-aware range
    # Range depends on skip_first_subnet: 0-44 (skip=false) or 0-43 (skip=true)
    precondition {
      condition = alltrue([
        for np in local.workers_manual :
        np.subnet_index >= 0 && np.subnet_index < local.manual_pool_size
      ])
      error_message = <<-EOT
        Worker nodepool subnet_index out of valid range!

        Invalid assignments: ${jsonencode([
          for np in local.workers_manual :
          { name = np.name, subnet_index = np.subnet_index }
          if np.subnet_index < 0 || np.subnet_index >= local.manual_pool_size
        ])}

        Valid range: 0-${local.manual_pool_size - 1} (${local.manual_pool_size} slots in manual assignment pool)

        Note: Available slots depend on skip_first_subnet setting.
      EOT
    }

    # Validate autoscaler subnet_index is within context-aware range
    precondition {
      condition = alltrue([
        for np in local.autoscalers_manual :
        np.subnet_index >= 0 && np.subnet_index < local.manual_pool_size
      ])
      error_message = <<-EOT
        Autoscaler nodepool subnet_index out of valid range!

        Invalid assignments: ${jsonencode([
          for np in local.autoscalers_manual :
          { name = np.name, subnet_index = np.subnet_index }
          if np.subnet_index < 0 || np.subnet_index >= local.manual_pool_size
        ])}

        Valid range: 0-${local.manual_pool_size - 1} (${local.manual_pool_size} slots in manual assignment pool)

        Note: Available slots depend on skip_first_subnet setting.
      EOT
    }

    # Validate no collisions between worker and autoscaler manual assignments
    precondition {
      condition     = !local.manual_assignment_collision
      error_message = <<-EOT
        Subnet collision detected! Multiple nodepools assigned to the same subnet slot.

        Worker manual assignments: ${jsonencode(local.worker_manual_slots)}
        Autoscaler manual assignments: ${jsonencode(local.autoscaler_manual_slots)}

        Colliding slot indices: ${jsonencode([
          for idx in distinct(local.all_manual_slot_indices) :
          idx if length([for s in local.all_manual_slot_indices : s if s == idx]) > 1
        ])}

        Available free slots (relative indices): ${jsonencode(local.manual_free_slots)}

        Fix: Assign different subnet_index values to avoid collisions.
        Each subnet_index (0-${local.manual_pool_size - 1}) can only be used once across ALL nodepools (workers + autoscalers).
      EOT
    }

    # Validate total manual assignments don't exceed pool size
    precondition {
      condition     = length(local.all_manual_slots) <= local.manual_pool_size
      error_message = <<-EOT
        Too many manual subnet assignments!

        Maximum allowed: ${local.manual_pool_size} (shared between workers and autoscalers)
        Current assignments: ${length(local.all_manual_slots)} (${length(local.workers_manual)} workers + ${length(local.autoscalers_manual)} autoscalers)

        Note: Workers and autoscalers without subnet_index will use shared subnets (no limit).
      EOT
    }
  }
}
