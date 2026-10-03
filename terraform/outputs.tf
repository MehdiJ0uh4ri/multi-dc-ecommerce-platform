output "cluster_version" {
  description = "Kubernetes API server version reached through var.kube_context."
  value       = data.kubernetes_server_version.this.version
}

output "kube_context" {
  value = var.kube_context
}

output "namespaces" {
  value = {
    dc1       = module.dc1.name
    dc2       = module.dc2.name
    operators = local.operators_namespace
  }
}

output "dc_nodes" {
  value = var.dc_nodes
}

output "network_policies" {
  value = keys(kubernetes_network_policy_v1.cross_namespace)
}

output "gateway_url" {
  description = "APISIX through the k3d load balancer (k3d/multidc-cluster.yaml maps 8080 -> 80)."
  value       = "http://localhost:8080"
}

output "data_tools" {
  description = "Phase 4.5: what the data-tools release runs (docs/data-layer.md)."
  value = var.enable_data_tools ? {
    image       = "registry.localhost:5000/platform/data-tools:${local.data_tools_version}"
    seed_orders = local.seed_orders && local.shopper_services_deployed ? "enabled" : (!local.olist_replay_found ? "skipped: run make olist-prepare" : "skipped: disabled or auth/order/payment-service not deployed")
    loadgen     = var.enable_loadgen && local.shopper_services_deployed
  } : null
}
