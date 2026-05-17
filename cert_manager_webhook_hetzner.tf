locals {
  cert_manager_webhook_hetzner_token = coalesce(var.cert_manager_webhook_hetzner_token, var.hcloud_token)

  cert_manager_webhook_hetzner_secret_manifest = var.cert_manager_webhook_hetzner_enabled ? {
    apiVersion = "v1"
    kind       = "Secret"
    type       = "Opaque"
    metadata = {
      name      = var.cert_manager_webhook_hetzner_secret_name
      namespace = data.helm_template.cert_manager_webhook_hetzner[0].namespace
    }
    data = {
      (var.cert_manager_webhook_hetzner_secret_key) = base64encode(local.cert_manager_webhook_hetzner_token)
    }
  } : null

  cert_manager_webhook_hetzner_values = {
    groupName    = var.cert_manager_webhook_hetzner_group_name
    replicaCount = local.control_plane_sum > 1 ? 2 : 1
    certManager = {
      namespace          = "cert-manager"
      serviceAccountName = "cert-manager"
    }
    podDisruptionBudget = {
      enabled        = true
      minAvailable   = null
      maxUnavailable = 1
    }
    nodeSelector = { "node-role.kubernetes.io/control-plane" : "" }
    tolerations = [
      {
        key      = "node-role.kubernetes.io/control-plane"
        effect   = "NoSchedule"
        operator = "Exists"
      }
    ]
  }
}

data "helm_template" "cert_manager_webhook_hetzner" {
  count = var.cert_manager_webhook_hetzner_enabled ? 1 : 0

  name      = "cert-manager-webhook-hetzner"
  namespace = "cert-manager"

  repository   = var.cert_manager_webhook_hetzner_helm_repository
  chart        = var.cert_manager_webhook_hetzner_helm_chart
  version      = var.cert_manager_webhook_hetzner_helm_version
  kube_version = var.kubernetes_version

  values = [
    yamlencode(local.cert_manager_webhook_hetzner_values),
    yamlencode(var.cert_manager_webhook_hetzner_helm_values)
  ]
}

locals {
  cert_manager_webhook_hetzner_manifest = var.cert_manager_webhook_hetzner_enabled ? {
    name     = "cert-manager-webhook-hetzner"
    contents = <<-EOF
      ${yamlencode(local.cert_manager_webhook_hetzner_secret_manifest)}
      ---
      ${data.helm_template.cert_manager_webhook_hetzner[0].manifest}
    EOF
  } : null
}
