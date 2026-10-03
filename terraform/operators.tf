# Cluster-wide operators. They run on the untainted server node (no DC pinning
# annotations on these namespaces) and manage CRs in both DC namespaces.
# Why operators instead of Bitnami charts: docs/decisions.md ADR-010.
resource "kubernetes_namespace_v1" "operators" {
  metadata {
    name = "platform-operators"
  }
}

locals {
  operators_namespace = kubernetes_namespace_v1.operators.metadata[0].name
  values_dir          = "${path.module}/../helm-values"
  vendor_charts       = "${path.module}/../charts/vendor"
  # Namespace created by the vendored RabbitMQ manifests (not configurable upstream).
  rabbitmq_operators_namespace = "rabbitmq-system"
}

# --- cert-manager: webhook certificates for cass-operator and the RabbitMQ operators (ADR-015)
resource "helm_release" "cert_manager" {
  name             = "cert-manager"
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  version          = var.chart_versions.cert_manager
  namespace        = "cert-manager"
  create_namespace = true

  values  = [file("${local.values_dir}/platform-operators/cert-manager.yaml")]
  timeout = 600
}

# --- DC1 + DC2 data-store operators ---------------------------------------------------
resource "helm_release" "strimzi" {
  name       = "strimzi"
  repository = "https://strimzi.io/charts/"
  chart      = "strimzi-kafka-operator"
  version    = var.chart_versions.strimzi
  namespace  = local.operators_namespace

  values = [
    file("${local.values_dir}/platform-operators/strimzi.yaml"),
    yamlencode({ watchNamespaces = [module.dc1.name, module.dc2.name] }),
  ]
  timeout = 600
}

resource "helm_release" "cloudnative_pg" {
  name       = "cnpg"
  repository = "https://cloudnative-pg.github.io/charts"
  chart      = "cloudnative-pg"
  version    = var.chart_versions.cloudnative_pg
  namespace  = local.operators_namespace

  values  = [file("${local.values_dir}/platform-operators/cloudnative-pg.yaml")]
  timeout = 600
}

resource "helm_release" "cass_operator" {
  name       = "cass-operator"
  repository = "https://helm.k8ssandra.io/stable"
  chart      = "cass-operator"
  version    = var.chart_versions.cass_operator
  namespace  = local.operators_namespace

  values  = [file("${local.values_dir}/platform-operators/cass-operator.yaml")]
  timeout = 600

  # Admission webhooks are on and get their serving certificate from cert-manager.
  depends_on = [helm_release.cert_manager]
}

# --- DC2 operators (Phase 4) ------------------------------------------------------------
resource "helm_release" "eck_operator" {
  # DC2 search Elasticsearch and the Phase 6 logging Elasticsearch/Kibana.
  count = var.enable_dc2 || var.enable_observability ? 1 : 0

  name       = "eck-operator"
  repository = "https://helm.elastic.co"
  chart      = "eck-operator"
  version    = var.chart_versions.eck_operator
  namespace  = local.operators_namespace

  values  = [file("${local.values_dir}/platform-operators/eck-operator.yaml")]
  timeout = 600
}

resource "helm_release" "mongodb_kubernetes" {
  count = var.enable_dc2 ? 1 : 0

  name       = "mongodb-kubernetes"
  repository = "https://mongodb.github.io/helm-charts"
  chart      = "mongodb-kubernetes"
  version    = var.chart_versions.mongodb_kubernetes
  namespace  = local.operators_namespace

  values = [
    file("${local.values_dir}/platform-operators/mongodb-kubernetes.yaml"),
    yamlencode({ operator = { watchNamespace = module.dc2.name } }),
  ]
  timeout = 600
}

# RabbitMQ publishes plain release manifests, no Helm chart: vendored unmodified under
# charts/vendor (sha256 in each Chart.yaml) so Terraform installs them like the others.
resource "helm_release" "rabbitmq_cluster_operator" {
  count = var.enable_dc2 ? 1 : 0

  name      = "rabbitmq-cluster-operator"
  chart     = "${local.vendor_charts}/rabbitmq-cluster-operator"
  namespace = local.operators_namespace
  timeout   = 600

  depends_on = [helm_release.cert_manager]
}

resource "helm_release" "rabbitmq_topology_operator" {
  count = var.enable_dc2 ? 1 : 0

  name      = "rabbitmq-topology-operator"
  chart     = "${local.vendor_charts}/rabbitmq-topology-operator"
  namespace = local.operators_namespace
  timeout   = 600

  depends_on = [helm_release.cert_manager, helm_release.rabbitmq_cluster_operator]
}
