locals {
  # StaticHostConfig documents - /etc/hosts entries
  # Creates one StaticHostConfig per IP address with its hostnames
  talos_manifest_statichostconfigs = length(local.talos_extra_host_entries) > 0 ? trimspace(join(
    "\n---\n",
    [
      for entry in local.talos_extra_host_entries : yamlencode({
        apiVersion = "v1alpha1"
        kind       = "StaticHostConfig"
        name       = entry.ip
        hostnames  = entry.aliases
      })
    ]
  )) : ""
}
