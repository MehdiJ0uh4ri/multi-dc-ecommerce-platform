# DC1 microservices: one Helm release per service (Phase 5 CI upgrades them individually).
locals {
  spring_service_chart = "${path.module}/../charts/spring-service"
  spring_service_chart_checksum = sha1(join("", [
    for f in sort(fileset(local.spring_service_chart, "**")) : filesha1("${local.spring_service_chart}/${f}")
  ]))
  dc1_services = yamldecode(file("${local.values_dir}/dc1-core/services.yaml"))
}

resource "helm_release" "dc1_service" {
  # var.dc1_services (profiles/*.tfvars) picks services explicitly; otherwise every entry
  # not marked `enabled: false` in services.yaml (e.g. tax-service, upstream defect).
  for_each = {
    for name, svc in local.dc1_services.services : name => svc
    if(var.dc1_services == null ? try(svc.enabled, true) : contains(var.dc1_services, name))
  }

  name      = each.key
  chart     = local.spring_service_chart
  namespace = module.dc1.name

  # Helm deep-merges these in order: shared settings, then the service entry.
  values = [
    yamlencode(local.dc1_services.common),
    yamlencode(each.value),
    yamlencode({ chartChecksum = local.spring_service_chart_checksum }),
  ]
  timeout = 900

  depends_on = [
    helm_release.dc1_datastores,
    helm_release.keycloak,
    kubernetes_service_v1.keycloak_alias,
    kubernetes_secret_v1.keycloak_admin,
  ]
}

# Debezium connectors, applied once the services have created their tables.
resource "helm_release" "dc1_cdc_connectors" {
  count = var.enable_cdc && var.enable_kafka ? 1 : 0

  name      = "cdc-connectors"
  chart     = local.datastores_chart
  namespace = module.dc1.name

  # Helm replaces lists instead of merging them, so the connector list is built here.
  values = [yamlencode({
    connectors = concat(
      yamldecode(file("${local.values_dir}/dc1-core/cdc-connectors.yaml")).connectors,
      var.enable_cassandra ? yamldecode(file("${local.values_dir}/dc1-core/cassandra-sink.yaml")).connectors : [],
    )
    chartChecksum = local.datastores_chart_checksum
  })]
  timeout = 600

  depends_on = [helm_release.dc1_service, helm_release.dc1_datastores]
}
