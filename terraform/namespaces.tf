module "dc1" {
  source = "./modules/dc-namespace"

  name           = "dc1-core"
  dc             = "dc1"
  zone_label_key = local.zone_label_key
  taint_key      = local.dc_taint_key
  quota          = var.dc_quotas["dc1"]
  # Chaos Mesh only targets namespaces carrying this annotation (enableFilterNamespace).
  extra_annotations  = var.enable_chaos ? { "chaos-mesh.org/inject" = "enabled" } : {}
  container_defaults = var.container_defaults

  depends_on = [kubernetes_labels.dc_node, kubernetes_node_taint.dc_node]
}

module "dc2" {
  source = "./modules/dc-namespace"

  name           = "dc2-analytics"
  dc             = "dc2"
  zone_label_key = local.zone_label_key
  taint_key      = local.dc_taint_key
  quota          = var.dc_quotas["dc2"]
  # Chaos Mesh only targets namespaces carrying this annotation (enableFilterNamespace).
  extra_annotations  = var.enable_chaos ? { "chaos-mesh.org/inject" = "enabled" } : {}
  container_defaults = var.container_defaults

  depends_on = [kubernetes_labels.dc_node, kubernetes_node_taint.dc_node]
}
