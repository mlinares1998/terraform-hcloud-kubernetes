locals {
  # Interfaces
  talos_public_interface_name    = "eth0"
  talos_public_interface_enabled = var.talos_public_ipv4_enabled || var.talos_public_ipv6_enabled
  talos_private_interface_name   = local.talos_public_interface_enabled ? "eth1" : "eth0"

  # Routes
  # Note: Default route (0.0.0.0/0) omits the 'network' key per Talos routing config requirements
  talos_extra_routes = [
    for cidr in var.talos_extra_routes : merge(
      { gateway = local.network_ipv4_gateway, metric = 512 },
      cidr != "0.0.0.0/0" ? { network = cidr } : {}
    )
  ]

  # Nameservers
  talos_nameservers = [
    for ns in var.talos_nameservers : ns
    if var.talos_ipv6_enabled || !strcontains(ns, ":")
  ]

  # User defined host entries
  talos_extra_host_entries = concat(
    var.kube_api_hostname != null ? [{ ip = local.kube_api_private_ipv4, aliases = [var.kube_api_hostname] }] : [],
    var.talos_extra_host_entries
  )

  # HostnameConfig - Hostname configuration
  # Talos will prioritize DHCP to provide hostname from Hetzner Cloud
  # Otherwise will generate the hostname based on machine identity
  talos_manifest_hostnameconfig = yamlencode({
    apiVersion = "v1alpha1"
    kind       = "HostnameConfig"
    auto       = "stable"
  })

  # Network - LinkConfig / DHCPv4Config
  talos_manifest_network = join("\n---\n", compact([
    local.talos_public_interface_enabled ? yamlencode({
      apiVersion = "v1alpha1"
      kind       = "LinkConfig"
      name       = local.talos_public_interface_name
      up         = true
    }) : null,
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "LinkConfig"
      name       = local.talos_private_interface_name
      up         = true
      routes     = local.talos_extra_routes
    }),
    local.talos_public_interface_enabled && var.talos_public_ipv4_enabled ? yamlencode({
      apiVersion = "v1alpha1"
      kind       = "DHCPv4Config"
      name       = local.talos_public_interface_name
    }) : null,
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "DHCPv4Config"
      name       = local.talos_private_interface_name
    })
  ]))

  # HCloudVIPConfig - Control Plane VIP
  talos_manifest_vips = join("\n---\n", compact([
    local.control_plane_public_vip_ipv4_enabled ? yamlencode({
      apiVersion = "v1alpha1"
      kind       = "HCloudVIPConfig"
      name       = local.control_plane_public_vip_ipv4
      link       = local.talos_public_interface_name
      apiToken   = var.hcloud_token
    }) : null,
    var.control_plane_private_vip_ipv4_enabled ? yamlencode({
      apiVersion = "v1alpha1"
      kind       = "HCloudVIPConfig"
      name       = local.control_plane_private_vip_ipv4
      link       = local.talos_private_interface_name
      apiToken   = var.hcloud_token
    }) : null
  ]))

  # ResolverConfig - DNS nameservers
  talos_manifest_resolverconfig = length(local.talos_nameservers) == 0 ? null : yamlencode({
    apiVersion  = "v1alpha1"
    kind        = "ResolverConfig"
    nameservers = [for ns in local.talos_nameservers : { address = ns }]
  })

  # StaticHostConfig - /etc/hosts entries
  talos_manifest_statichostconfigs = length(local.talos_extra_host_entries) == 0 ? null : join("\n---\n", [
    for entry in local.talos_extra_host_entries : yamlencode({
      apiVersion = "v1alpha1"
      kind       = "StaticHostConfig"
      name       = entry.ip
      hostnames  = entry.aliases
    })
  ])

  # TimeSyncConfig - NTP configuration
  talos_manifest_timesyncconfig = yamlencode({
    apiVersion = "v1alpha1"
    kind       = "TimeSyncConfig"
    ntp        = { servers = var.talos_time_servers }
  })
}
