# Simulated datacenter topology: one k3d agent node per DC.
# The server node stays untainted and runs cluster add-ons (CoreDNS, local-path, metrics-server).
locals {
  zone_label_key = "topology.kubernetes.io/zone"
  dc_taint_key   = "platform.local/dc"
}

resource "kubernetes_labels" "dc_node" {
  for_each = var.dc_nodes

  api_version = "v1"
  kind        = "Node"
  # Each node resource needs its own server-side-apply field manager. With the
  # shared default ("Terraform"), the labels apply dropped the taints the other
  # resource had just applied.
  field_manager = "terraform-dc-labels"
  metadata {
    name = each.value
  }
  labels = {
    (local.zone_label_key) = each.key
    (local.dc_taint_key)   = each.key
  }
}

resource "kubernetes_node_taint" "dc_node" {
  for_each = var.dc_nodes

  field_manager = "terraform-dc-taints"
  metadata {
    name = each.value
  }
  taint {
    key    = local.dc_taint_key
    value  = each.key
    effect = "NoSchedule"
  }
}
