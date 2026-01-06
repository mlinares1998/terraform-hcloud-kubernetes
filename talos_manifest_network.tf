locals {
  # Interface Configuration
  talos_public_interface_name    = "eth0"
  talos_public_interface_enabled = var.talos_public_ipv4_enabled || var.talos_public_ipv6_enabled
  talos_private_interface_name   = local.talos_public_interface_enabled ? "eth1" : "eth0"

  # Routes
  talos_extra_routes = [for cidr in var.talos_extra_routes : merge(
    {
      gateway = local.network_ipv4_gateway
      metric  = 512
    },
    cidr != "0.0.0.0/0" ? { network = cidr } : {}
  )]

  # Control plane network documents
  control_plane_network_documents = trimspace(join(
    "\n---\n",
    compact([
      # Public interface LinkConfig (if enabled)
      local.talos_public_interface_enabled ? yamlencode({
        apiVersion = "v1alpha1"
        kind       = "LinkConfig"
        name       = local.talos_public_interface_name
        up         = true
      }) : null,

      # Private interface LinkConfig with routes
      yamlencode({
        apiVersion = "v1alpha1"
        kind       = "LinkConfig"
        name       = local.talos_private_interface_name
        up         = true
        routes     = local.talos_extra_routes
      }),

      # Public interface DHCPv4Config (if enabled)
      local.talos_public_interface_enabled && var.talos_public_ipv4_enabled ? yamlencode({
        apiVersion = "v1alpha1"
        kind       = "DHCPv4Config"
        name       = local.talos_public_interface_name
      }) : null,

      # Private interface DHCPv4Config
      yamlencode({
        apiVersion = "v1alpha1"
        kind       = "DHCPv4Config"
        name       = local.talos_private_interface_name
      }),

      # Public VIP HCloudVIPConfig (if enabled)
      local.control_plane_public_vip_ipv4_enabled ? yamlencode({
        apiVersion = "v1alpha1"
        kind       = "HCloudVIPConfig"
        name       = local.control_plane_public_vip_ipv4
        link       = local.talos_public_interface_name
        apiToken   = var.hcloud_token
      }) : null,

      # Private VIP HCloudVIPConfig (if enabled)
      var.control_plane_private_vip_ipv4_enabled ? yamlencode({
        apiVersion = "v1alpha1"
        kind       = "HCloudVIPConfig"
        name       = local.control_plane_private_vip_ipv4
        link       = local.talos_private_interface_name
        apiToken   = var.hcloud_token
      }) : null,
    ])
  ))

  # Worker network documents (no VIP configuration)
  worker_network_documents = trimspace(join(
    "\n---\n",
    compact([
      # Public interface LinkConfig (if enabled)
      local.talos_public_interface_enabled ? yamlencode({
        apiVersion = "v1alpha1"
        kind       = "LinkConfig"
        name       = local.talos_public_interface_name
        up         = true
      }) : null,

      # Private interface LinkConfig with routes
      yamlencode({
        apiVersion = "v1alpha1"
        kind       = "LinkConfig"
        name       = local.talos_private_interface_name
        up         = true
        routes     = local.talos_extra_routes
      }),

      # Public interface DHCPv4Config (if enabled)
      local.talos_public_interface_enabled && var.talos_public_ipv4_enabled ? yamlencode({
        apiVersion = "v1alpha1"
        kind       = "DHCPv4Config"
        name       = local.talos_public_interface_name
      }) : null,

      # Private interface DHCPv4Config
      yamlencode({
        apiVersion = "v1alpha1"
        kind       = "DHCPv4Config"
        name       = local.talos_private_interface_name
      }),
    ])
  ))
}
