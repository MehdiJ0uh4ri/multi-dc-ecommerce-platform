# Keycloak (identity) and APISIX (gateway) in DC1.

# --- Keycloak ----------------------------------------------------------------
resource "kubernetes_secret_v1" "keycloak_admin" {
  metadata {
    name      = "keycloak-admin"
    namespace = module.dc1.name
  }
  data = {
    username = "admin"
    password = var.datastore_passwords["dc1_keycloak_admin"]
  }
}

# Upstream realm export: realm "ecommerce", public client "ecommerce-client", test users.
resource "kubernetes_config_map_v1" "keycloak_realm" {
  metadata {
    name      = "keycloak-realm"
    namespace = module.dc1.name
  }
  data = {
    "ecommerce-realm.json" = file("${path.module}/../app/docker/keycloak/import/ecommerce-realm.json")
  }
}

resource "helm_release" "keycloak" {
  name       = "keycloak"
  repository = "https://codecentric.github.io/helm-charts"
  chart      = "keycloakx"
  version    = var.chart_versions.keycloakx
  namespace  = module.dc1.name

  values = [
    file("${local.values_dir}/dc1-core/keycloak.yaml"),
    # Metrics on the management port (/metrics); KC_METRICS_ENABLED is set by the chart.
    yamlencode({ serviceMonitor = { enabled = var.enable_observability } }),
  ]
  timeout = 900

  depends_on = [
    helm_release.kube_prometheus_stack,
    helm_release.dc1_datastores,
    kubernetes_secret_v1.keycloak_admin,
    kubernetes_config_map_v1.keycloak_realm,
  ]
}

# Stable name/port expected by the upstream APISIX routes (http://keycloak:8080) and by
# the issuer URL set with --hostname. The chart's own Service is keycloak-http:80.
resource "kubernetes_service_v1" "keycloak_alias" {
  metadata {
    name      = "keycloak"
    namespace = module.dc1.name
  }
  spec {
    selector = { (local.role_label) = "keycloak" }
    port {
      name        = "http"
      port        = 8080
      target_port = "http"
    }
  }
}

# --- APISIX ------------------------------------------------------------------
# Upstream standalone routes, unchanged except the client secret placeholder:
# ecommerce-client is public and APISIX validates bearer tokens via JWKS, so the
# secret is never used. Replacing it avoids exposing env vars to nginx workers.
resource "kubernetes_config_map_v1" "apisix_routes" {
  metadata {
    name      = "apisix-routes"
    namespace = module.dc1.name
  }
  data = {
    "apisix.yaml" = replace(
      file("${path.module}/../app/deploy/apisix/apisix.yaml"),
      "$env://KEYCLOAK_CLIENT_SECRET",
      "unused-public-client",
    )
  }
}

resource "helm_release" "apisix" {
  name       = "apisix"
  repository = "https://charts.apiseven.com"
  chart      = "apisix"
  version    = var.chart_versions.apisix
  namespace  = module.dc1.name

  values = [
    file("${local.values_dir}/dc1-core/apisix.yaml"),
    # Prometheus plugin export on :9091 (the routes file enables the plugin globally);
    # the chart's ServiceMonitor switch is the top-level metrics.serviceMonitor.
    yamlencode({
      apisix  = { prometheus = { enabled = true } }
      metrics = { serviceMonitor = { enabled = var.enable_observability } }
    }),
  ]
  timeout = 600

  depends_on = [kubernetes_config_map_v1.apisix_routes, helm_release.kube_prometheus_stack]
}

# External entry point: http://localhost:8080 -> k3d load balancer -> DC1 node :80 -> APISIX.
# - externalTrafficPolicy=Local: k3s publishes node IPs as LoadBalancer IPs, so kube-proxy
#   handles the traffic; with "Cluster" it SNATs to a node address and the NetworkPolicy
#   refuses it. Local keeps the k3d-network source (allow-external-to-gateway ipBlock).
# - The toleration annotation lets the servicelb pod run on the tainted DC1 node. It must
#   exist when the Service is created: with Local, k3s publishes no address until that
#   pod runs next to APISIX, and anything waiting for the address would hang.
resource "kubernetes_service_v1" "apisix_external" {
  metadata {
    name      = "apisix-external"
    namespace = module.dc1.name
    annotations = {
      "svccontroller.k3s.cattle.io/tolerations" = jsonencode([{
        key      = local.dc_taint_key
        operator = "Equal"
        value    = "dc1"
        effect   = "NoSchedule"
      }])
    }
  }
  spec {
    type                    = "LoadBalancer"
    external_traffic_policy = "Local"
    selector                = { (local.role_label) = "api-gateway" }
    port {
      name        = "http"
      port        = 80
      target_port = 9080
    }
  }
  wait_for_load_balancer = true

  depends_on = [helm_release.apisix]
}
