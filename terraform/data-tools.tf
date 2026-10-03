# Phase 4.5 data layer: seeders and load generator (charts/data-tools, docs/data-layer.md).
# Runs in dc1-core and reaches APISIX, Keycloak and kafka-dc1 through allow-same-namespace;
# no new NetworkPolicy. The Keycloak client platform-seeder is managed by the separate
# root module terraform/keycloak (`make keycloak-config`).
locals {
  data_tools_chart = "${path.module}/../charts/data-tools"
  data_tools_chart_checksum = sha1(join("", [
    for f in sort(fileset(local.data_tools_chart, "**")) : filesha1("${local.data_tools_chart}/${f}")
  ]))
  data_tools_version = trimspace(file("${path.module}/../data-tools/VERSION"))
  # Written by `make olist-prepare` from the gitignored Olist CSVs.
  olist_replay_file  = "${path.module}/../data-tools/data/olist-replay.jsonl.gz"
  olist_replay_found = fileexists(local.olist_replay_file)
  seed_orders        = var.enable_data_tools && var.enable_seed_orders && local.olist_replay_found
  # Services each tool calls; with one missing the Job or Deployment could never succeed.
  shopper_services_deployed = alltrue([
    for s in ["auth-service", "order-service", "payment-service"] : contains(keys(helm_release.dc1_service), s)
  ])
}

resource "kubernetes_secret_v1" "data_tools_seeder_client" {
  count = var.enable_data_tools ? 1 : 0

  metadata {
    name      = "data-tools-seeder-client"
    namespace = module.dc1.name
  }
  data = {
    client_id     = "platform-seeder"
    client_secret = lookup(var.datastore_passwords, "dc1_keycloak_seeder_client", "")
  }

  lifecycle {
    precondition {
      condition     = lookup(var.datastore_passwords, "dc1_keycloak_seeder_client", "") != ""
      error_message = "Phase 4.5 secrets are missing: run `make secrets` again (it keeps existing passwords)."
    }
  }
}

# One shared password for every synthetic shopper (seed-orders, loadgen).
resource "kubernetes_secret_v1" "data_tools_users" {
  count = var.enable_data_tools ? 1 : 0

  metadata {
    name      = "data-tools-users"
    namespace = module.dc1.name
  }
  data = {
    password = lookup(var.datastore_passwords, "data_tools_user_password", "")
  }

  lifecycle {
    precondition {
      condition     = lookup(var.datastore_passwords, "data_tools_user_password", "") != ""
      error_message = "Phase 4.5 secrets are missing: run `make secrets` again (it keeps existing passwords)."
    }
  }
}

resource "kubernetes_config_map_v1" "olist_replay" {
  count = local.seed_orders ? 1 : 0

  metadata {
    name      = "olist-replay"
    namespace = module.dc1.name
  }
  binary_data = {
    # Guarded here too: `terraform validate` evaluates this even when count is 0.
    "olist-replay.jsonl.gz" = local.olist_replay_found ? filebase64(local.olist_replay_file) : ""
  }
}

resource "helm_release" "data_tools" {
  count = var.enable_data_tools ? 1 : 0

  name      = "data-tools"
  chart     = local.data_tools_chart
  namespace = module.dc1.name

  values = [
    file("${local.values_dir}/dc1-core/data-tools.yaml"),
    yamlencode({
      image    = { tag = local.data_tools_version }
      platform = { orderContextEnabled = var.enable_kafka }
      seedOrders = {
        enabled      = local.seed_orders && local.shopper_services_deployed
        dataChecksum = local.olist_replay_found ? filesha256(local.olist_replay_file) : ""
      }
      loadgen       = { enabled = var.enable_loadgen && local.shopper_services_deployed }
      metrics       = { enabled = var.enable_observability }
      chartChecksum = local.data_tools_chart_checksum
    }),
  ]
  timeout = 600
  # The Jobs run for minutes (seed-orders for tens of minutes); verify-phase4.5 waits for them.
  wait_for_jobs = false

  depends_on = [
    helm_release.dc1_service,
    helm_release.apisix,
    kubernetes_service_v1.keycloak_alias,
    kubernetes_secret_v1.data_tools_seeder_client,
    kubernetes_secret_v1.data_tools_users,
    kubernetes_config_map_v1.olist_replay,
    helm_release.kube_prometheus_stack,
  ]
}
