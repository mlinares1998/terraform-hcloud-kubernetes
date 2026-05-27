data "helm_template" "cert_manager_webhook_hetzner" {
  count = var.cert_manager_webhook_hetzner_enabled ? 1 : 0

  name      = "cert-manager-webhook-hetzner"
  namespace = "cert-manager"

  repository   = var.cert_manager_webhook_hetzner_helm_repository
  chart        = var.cert_manager_webhook_hetzner_helm_chart
  version      = var.cert_manager_webhook_hetzner_helm_version
  kube_version = var.kubernetes_version

  values = [
    yamlencode({
      groupName    = var.cert_manager_webhook_hetzner_group_name
      replicaCount = local.control_plane_sum > 1 ? 2 : 1
      podDisruptionBudget = {
        enabled        = true
        maxUnavailable = 1
      }
      affinity = local.control_plane_sum > 1 ? {
        podAntiAffinity = {
          requiredDuringSchedulingIgnoredDuringExecution = [
            {
              labelSelector = {
                matchLabels = {
                  app     = "cert-manager-webhook-hetzner"
                  release = "cert-manager-webhook-hetzner"
                }
              }
              topologyKey = "kubernetes.io/hostname"
            }
          ]
        }
      } : {}
      nodeSelector = { "node-role.kubernetes.io/control-plane" : "" }
      tolerations = [
        {
          key      = "node-role.kubernetes.io/control-plane"
          effect   = "NoSchedule"
          operator = "Exists"
        }
      ],
    }),
    yamlencode(var.cert_manager_webhook_hetzner_helm_values)
  ]
}

locals {
  cert_manager_webhook_hetzner_manifest = var.cert_manager_webhook_hetzner_enabled ? {
    name     = "cert-manager-webhook-hetzner"
    contents = data.helm_template.cert_manager_webhook_hetzner[0].manifest
  } : null
}
