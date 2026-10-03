# DC2 (analytics/read side) data stores, Phase 4. Everything here is gated by var.enable_dc2.
# CRs are rendered by charts/datastores with helm-values/dc2-analytics/datastores.yaml.
locals {
  dc2_values_dir = "${local.values_dir}/dc2-analytics"
}

resource "kubernetes_secret_v1" "dc2_pg_ecommerce" {
  count = var.enable_dc2 ? 1 : 0

  metadata {
    name      = "pg-dc2-ecommerce"
    namespace = module.dc2.name
    labels    = { "cnpg.io/reload" = "true" }
  }
  type = "kubernetes.io/basic-auth"
  data = {
    username = "ecommerce"
    password = var.datastore_passwords["dc2_pg_ecommerce"]
  }
}

# Referenced by the MongoDBCommunity user "analytics" (passwordSecretRef).
resource "kubernetes_secret_v1" "dc2_mongo_analytics" {
  count = var.enable_dc2 ? 1 : 0

  metadata {
    name      = "mongo-dc2-analytics-password"
    namespace = module.dc2.name
  }
  data = {
    password = var.datastore_passwords["dc2_mongo_analytics"]
  }
}

# RustFS root credentials; media-service uses the same keys (STORAGE_ACCESS/SECRET_KEY).
resource "kubernetes_secret_v1" "dc2_rustfs" {
  count = var.enable_dc2 ? 1 : 0

  metadata {
    name      = "rustfs-dc2-credentials"
    namespace = module.dc2.name
  }
  data = {
    RUSTFS_ACCESS_KEY = "ecommerce-media"
    RUSTFS_SECRET_KEY = var.datastore_passwords["dc2_rustfs_secret_key"]
  }
}

resource "helm_release" "dc2_datastores" {
  count = var.enable_dc2 ? 1 : 0

  name      = "datastores"
  chart     = local.datastores_chart
  namespace = module.dc2.name

  values = [
    file("${local.dc2_values_dir}/datastores.yaml"),
    yamlencode({
      metrics       = { enabled = var.enable_observability }
      chartChecksum = local.datastores_chart_checksum
    }),
  ]
  timeout = 900

  depends_on = [
    helm_release.strimzi,
    helm_release.cloudnative_pg,
    helm_release.eck_operator,
    helm_release.mongodb_kubernetes,
    helm_release.rabbitmq_cluster_operator,
    helm_release.rabbitmq_topology_operator,
    kubernetes_secret_v1.dc2_pg_ecommerce,
    kubernetes_secret_v1.dc2_mongo_analytics,
    kubernetes_network_policy_v1.cross_namespace,
    # MirrorMaker 2 pulls from kafka-dc1.
    helm_release.dc1_datastores,
  ]
}

resource "helm_release" "dc2_rustfs" {
  count = var.enable_dc2 ? 1 : 0

  name       = "rustfs"
  repository = "https://charts.rustfs.com"
  chart      = "rustfs"
  version    = var.chart_versions.rustfs
  namespace  = module.dc2.name

  values  = [file("${local.dc2_values_dir}/rustfs.yaml")]
  timeout = 600

  depends_on = [kubernetes_secret_v1.dc2_rustfs]
}

resource "helm_release" "dc2_mailpit" {
  count = var.enable_dc2 ? 1 : 0

  name       = "mailpit"
  repository = "https://jouve.github.io/charts"
  chart      = "mailpit"
  version    = var.chart_versions.mailpit
  namespace  = module.dc2.name

  values  = [file("${local.dc2_values_dir}/mailpit.yaml")]
  timeout = 300
}

# Sink connectors on connect-dc2 (MongoDB, RabbitMQ). Separate release so they are only
# created once the Connect cluster, MongoDB and RabbitMQ exist.
resource "helm_release" "dc2_connectors" {
  count = var.enable_dc2 ? 1 : 0

  name      = "dc2-connectors"
  chart     = local.datastores_chart
  namespace = module.dc2.name

  values = [
    file("${local.dc2_values_dir}/connectors.yaml"),
    yamlencode({ chartChecksum = local.datastores_chart_checksum }),
  ]
  timeout = 600

  depends_on = [helm_release.dc2_datastores]
}
