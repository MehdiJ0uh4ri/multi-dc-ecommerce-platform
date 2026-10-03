# DC2 microservices (Phase 4): one Helm release per service, like DC1.
locals {
  dc2_services = yamldecode(file("${local.dc2_values_dir}/services.yaml"))
  dc2_enabled_services = {
    for name, svc in local.dc2_services.services : name => svc if var.enable_dc2 && try(svc.enabled, true)
  }
}

resource "helm_release" "dc2_service" {
  for_each = local.dc2_enabled_services

  name      = each.key
  chart     = local.spring_service_chart
  namespace = module.dc2.name

  values = [
    yamlencode(local.dc2_services.common),
    yamlencode(each.value),
    yamlencode({ chartChecksum = local.spring_service_chart_checksum }),
  ]
  timeout = 900

  depends_on = [
    helm_release.dc2_datastores,
    helm_release.dc2_rustfs,
    helm_release.dc2_mailpit,
    helm_release.keycloak,
    kubernetes_service_v1.keycloak_alias,
    kubernetes_network_policy_v1.cross_namespace,
  ]
}

# APISIX (DC1) routes use the upstream short names (favourite-service:8081, ...).
# These ExternalName aliases in dc1-core resolve them to the DC2 Services; the traffic
# itself is admitted by allow-dc1-gateway-to-services.
resource "kubernetes_service_v1" "dc2_service_alias" {
  for_each = local.dc2_enabled_services

  metadata {
    name      = each.key
    namespace = module.dc1.name
  }
  spec {
    type          = "ExternalName"
    external_name = "${each.key}.${module.dc2.name}.svc.cluster.local"
  }
}
