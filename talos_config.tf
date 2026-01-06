data "talos_machine_configuration" "control_plane" {
  for_each = { for node in hcloud_server.control_plane : node.name => node }

  talos_version      = var.talos_version
  cluster_name       = var.cluster_name
  cluster_endpoint   = local.kube_api_url_internal
  kubernetes_version = var.kubernetes_version
  machine_type       = "controlplane"
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  docs               = false
  examples           = false

  config_patches = concat(
    # Main v1alpha1 machine configuration
    [yamlencode(local.control_plane_talos_config_patch[each.key])],
    # HostnameConfig document
    [local.talos_manifest_hostnameconfig],
    # ResolverConfig document - DNS nameservers
    local.talos_manifest_resolverconfig != null ? [local.talos_manifest_resolverconfig] : [],
    # StaticHostConfig documents - /etc/hosts entries
    local.talos_manifest_statichostconfigs != "" ? [local.talos_manifest_statichostconfigs] : [],
    # VolumeConfig documents - system disk encryption
    length(local.talos_manifest_volumeconfigs) > 0 ? [local.talos_manifest_volumeconfigs] : [],
    # User-provided configuration patches
    [for patch in var.control_plane_config_patches : yamlencode(patch)]
  )
}

data "talos_machine_configuration" "worker" {
  for_each = { for node in hcloud_server.worker : node.name => node }

  talos_version      = var.talos_version
  cluster_name       = var.cluster_name
  cluster_endpoint   = local.kube_api_url_internal
  kubernetes_version = var.kubernetes_version
  machine_type       = "worker"
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  docs               = false
  examples           = false

  config_patches = concat(
    # Main v1alpha1 machine configuration
    [yamlencode(local.worker_talos_config_patch[each.key])],
    # HostnameConfig document
    [local.talos_manifest_hostnameconfig],
    # ResolverConfig document - DNS nameservers
    local.talos_manifest_resolverconfig != null ? [local.talos_manifest_resolverconfig] : [],
    # StaticHostConfig documents - /etc/hosts entries
    local.talos_manifest_statichostconfigs != "" ? [local.talos_manifest_statichostconfigs] : [],
    # VolumeConfig documents - system disk encryption
    length(local.talos_manifest_volumeconfigs) > 0 ? [local.talos_manifest_volumeconfigs] : [],
    # User-provided configuration patches
    [for patch in var.worker_config_patches : yamlencode(patch)]
  )
}

data "talos_machine_configuration" "cluster_autoscaler" {
  for_each = { for nodepool in local.cluster_autoscaler_nodepools : nodepool.name => nodepool }

  talos_version      = var.talos_version
  cluster_name       = var.cluster_name
  cluster_endpoint   = local.kube_api_url_internal
  kubernetes_version = var.kubernetes_version
  machine_type       = "worker"
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  docs               = false
  examples           = false

  config_patches = concat(
    # Main v1alpha1 machine configuration
    [yamlencode(local.autoscaler_talos_config_patch[each.key])],
    # HostnameConfig document
    [local.talos_manifest_hostnameconfig],
    # ResolverConfig document - DNS nameservers
    local.talos_manifest_resolverconfig != null ? [local.talos_manifest_resolverconfig] : [],
    # StaticHostConfig documents - /etc/hosts entries
    local.talos_manifest_statichostconfigs != "" ? [local.talos_manifest_statichostconfigs] : [],
    # VolumeConfig documents - system disk encryption
    length(local.talos_manifest_volumeconfigs) > 0 ? [local.talos_manifest_volumeconfigs] : [],
    # User-provided configuration patches
    [for patch in var.cluster_autoscaler_config_patches : yamlencode(patch)]
  )
}
