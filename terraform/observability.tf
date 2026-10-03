# Phase 6 — observability. Metrics: kube-prometheus-stack + monitors (charts/observability)
# + exporters. Logs: Fluent Bit -> ECK Elasticsearch/Kibana. Uptime/alerting: Icinga and
# Alertmanager, both mailing Mailpit. Everything is gated by var.enable_observability.
locals {
  monitoring_namespace = "monitoring"
  logging_namespace    = "logging"
  monitoring_values    = "${local.values_dir}/monitoring"
  dashboards_dir       = "${path.module}/../monitoring/grafana-dashboards"
  observability_on     = var.enable_observability
  mailpit_smtp         = "mailpit-smtp.${module.dc2.name}.svc.cluster.local"

  # Alertmanager routes everything except Watchdog to Mailpit (DC2). Without DC2 there is
  # no mail sink, so alerts are only visible in the Alertmanager/Grafana UIs.
  # The two configs have different shapes, so the choice is made on JSON strings.
  alertmanager_config = jsondecode(var.enable_dc2 ? jsonencode({
    global = {
      smtp_smarthost   = "${local.mailpit_smtp}:25"
      smtp_from        = "alertmanager@platform.local"
      smtp_require_tls = false
    }
    route = {
      receiver        = "platform-oncall"
      group_by        = ["alertname", "namespace"]
      group_wait      = "30s"
      group_interval  = "5m"
      repeat_interval = "4h"
      routes          = [{ receiver = "null", matchers = ["alertname = Watchdog"] }]
    }
    receivers = [
      { name = "null" },
      { name = "platform-oncall", email_configs = [{ to = "oncall@platform.local", send_resolved = true }] },
    ]
    }) : jsonencode({
    global    = {}
    route     = { receiver = "null", group_by = ["alertname", "namespace"], routes = [] }
    receivers = [{ name = "null" }, { name = "platform-oncall" }]
  }))
}

resource "kubernetes_namespace_v1" "monitoring" {
  count = local.observability_on ? 1 : 0
  metadata {
    name = local.monitoring_namespace
  }
}

resource "kubernetes_namespace_v1" "logging" {
  count = local.observability_on ? 1 : 0
  metadata {
    name = local.logging_namespace
  }
}

# --- Metrics -----------------------------------------------------------------------
resource "kubernetes_secret_v1" "grafana_admin" {
  count = local.observability_on ? 1 : 0
  metadata {
    name      = "grafana-admin"
    namespace = kubernetes_namespace_v1.monitoring[0].metadata[0].name
  }
  data = {
    admin-user     = "admin"
    admin-password = var.datastore_passwords["grafana_admin"]
  }
}

resource "helm_release" "kube_prometheus_stack" {
  count = local.observability_on ? 1 : 0

  name       = "kube-prometheus-stack"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  version    = var.chart_versions.kube_prometheus_stack
  namespace  = kubernetes_namespace_v1.monitoring[0].metadata[0].name

  values = [
    file("${local.monitoring_values}/kube-prometheus-stack.yaml"),
    yamlencode({ alertmanager = { config = local.alertmanager_config } }),
  ]
  timeout = 900

  depends_on = [kubernetes_secret_v1.grafana_admin]
}

# Grafana sidecar loads every ConfigMap labelled grafana_dashboard=1 (all namespaces).
resource "kubernetes_config_map_v1" "grafana_dashboard" {
  for_each = local.observability_on ? fileset(local.dashboards_dir, "*.json") : []

  metadata {
    name        = "dashboard-${trimsuffix(each.key, ".json")}"
    namespace   = kubernetes_namespace_v1.monitoring[0].metadata[0].name
    labels      = { grafana_dashboard = "1" }
    annotations = { grafana_folder = "Platform" }
  }
  data = {
    (each.key) = file("${local.dashboards_dir}/${each.key}")
  }
}

# PodMonitors/ServiceMonitors for both DCs, alert rules, and the logging Elasticsearch/Kibana.
resource "helm_release" "observability" {
  count = local.observability_on ? 1 : 0

  name      = "observability"
  chart     = "${path.module}/../charts/observability"
  namespace = kubernetes_namespace_v1.monitoring[0].metadata[0].name

  values = [yamlencode({
    dcNamespaces       = concat([module.dc1.name], var.enable_dc2 ? [module.dc2.name] : [])
    operatorsNamespace = local.operators_namespace
    logging = {
      enabled   = true
      namespace = kubernetes_namespace_v1.logging[0].metadata[0].name
      resources = {
        requests = { cpu = "250m", memory = "2Gi" }
        limits   = { cpu = "2", memory = "2Gi" }
      }
      kibana = {
        resources = {
          requests = { cpu = "100m", memory = "1Gi" }
          limits   = { cpu = "1", memory = "1Gi" }
        }
      }
    }
  })]
  timeout = 900

  depends_on = [helm_release.kube_prometheus_stack, helm_release.eck_operator]
}

# --- Logs --------------------------------------------------------------------------
resource "helm_release" "fluent_bit" {
  count = local.observability_on ? 1 : 0

  name       = "fluent-bit"
  repository = "https://fluent.github.io/helm-charts"
  chart      = "fluent-bit"
  version    = var.chart_versions.fluent_bit
  namespace  = kubernetes_namespace_v1.logging[0].metadata[0].name

  values  = [file("${local.monitoring_values}/fluent-bit.yaml")]
  timeout = 600

  # es-logs (and its elastic-user Secret) is created by the observability release.
  depends_on = [helm_release.observability]
}

# --- DC2 exporters (next to the stores, for same-namespace credential Secrets) ------
resource "helm_release" "elasticsearch_exporter" {
  count = local.observability_on && var.enable_dc2 ? 1 : 0

  name       = "elasticsearch-exporter"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "prometheus-elasticsearch-exporter"
  version    = var.chart_versions.elasticsearch_exporter
  namespace  = module.dc2.name

  values  = [file("${local.dc2_values_dir}/elasticsearch-exporter.yaml")]
  timeout = 300

  depends_on = [helm_release.dc2_datastores, helm_release.kube_prometheus_stack]
}

resource "helm_release" "mongodb_exporter" {
  count = local.observability_on && var.enable_dc2 ? 1 : 0

  name       = "mongodb-exporter"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "prometheus-mongodb-exporter"
  version    = var.chart_versions.mongodb_exporter
  namespace  = module.dc2.name

  values  = [file("${local.dc2_values_dir}/mongodb-exporter.yaml")]
  timeout = 300

  depends_on = [helm_release.dc2_datastores, helm_release.kube_prometheus_stack]
}

# --- Icinga (uptime + alerting on data stores and Kafka) -----------------------------
resource "kubernetes_secret_v1" "icinga_api" {
  count = local.observability_on ? 1 : 0
  metadata {
    name      = "icinga-api"
    namespace = kubernetes_namespace_v1.monitoring[0].metadata[0].name
  }
  data = {
    ticket-salt = var.datastore_passwords["icinga_ticket_salt"]
    root        = var.datastore_passwords["icinga_api_root"]
    icingaweb   = var.datastore_passwords["icinga_api_icingaweb"]
  }
}

resource "kubernetes_secret_v1" "icingaweb_admin" {
  count = local.observability_on ? 1 : 0
  metadata {
    name      = "icingaweb-admin"
    namespace = kubernetes_namespace_v1.monitoring[0].metadata[0].name
  }
  data = {
    password = var.datastore_passwords["icingaweb_admin"]
  }
}

resource "kubernetes_secret_v1" "pg_monitoring_icinga" {
  count = local.observability_on ? 1 : 0
  metadata {
    name      = "pg-monitoring-icinga"
    namespace = kubernetes_namespace_v1.monitoring[0].metadata[0].name
    labels    = { "cnpg.io/reload" = "true" }
  }
  type = "kubernetes.io/basic-auth"
  data = {
    username = "icinga"
    password = var.datastore_passwords["monitoring_pg_icinga"]
  }
}

# PostgreSQL for Icinga DB + Icinga Web 2 (same CloudNativePG chart as the DCs).
resource "helm_release" "pg_monitoring" {
  count = local.observability_on ? 1 : 0

  name      = "pg-monitoring"
  chart     = local.datastores_chart
  namespace = kubernetes_namespace_v1.monitoring[0].metadata[0].name

  values = [
    file("${local.monitoring_values}/pg-monitoring.yaml"),
    yamlencode({ chartChecksum = local.datastores_chart_checksum }),
  ]
  timeout = 600

  depends_on = [helm_release.cloudnative_pg, kubernetes_secret_v1.pg_monitoring_icinga]
}

resource "helm_release" "icinga" {
  count = local.observability_on ? 1 : 0

  name      = "icinga"
  chart     = "${path.module}/../charts/icinga"
  namespace = kubernetes_namespace_v1.monitoring[0].metadata[0].name

  values = [
    file("${local.monitoring_values}/icinga.yaml"),
    yamlencode({
      checks = templatefile("${path.module}/../monitoring/icinga/platform.conf.tftpl", {
        enable_kafka     = var.enable_kafka
        enable_cdc       = var.enable_cdc && var.enable_kafka
        enable_cassandra = var.enable_cassandra
        enable_dc2       = var.enable_dc2
      })
      mail = { host = var.enable_dc2 ? local.mailpit_smtp : "localhost" }
    }),
  ]
  timeout = 600

  depends_on = [
    helm_release.pg_monitoring,
    kubernetes_secret_v1.icinga_api,
    kubernetes_secret_v1.icingaweb_admin,
  ]
}
