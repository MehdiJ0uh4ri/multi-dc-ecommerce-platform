# Phase 7 — Chaos Mesh. Experiments are not applied by Terraform: they live in
# chaos/experiments and scripts/chaos-demo.sh applies, observes and removes them
# (docs/chaos-runbook.md). Only namespaces annotated chaos-mesh.org/inject=enabled
# (the DC namespaces, via modules/dc-namespace) can be targeted.
resource "helm_release" "chaos_mesh" {
  count = var.enable_chaos ? 1 : 0

  name             = "chaos-mesh"
  repository       = "https://charts.chaos-mesh.org"
  chart            = "chaos-mesh"
  version          = var.chart_versions.chaos_mesh
  namespace        = "chaos-mesh"
  create_namespace = true

  values  = [file("${local.values_dir}/chaos/chaos-mesh.yaml")]
  timeout = 600
}
