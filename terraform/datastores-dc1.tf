# DC1 data stores: PostgreSQL (CloudNativePG), Kafka (Strimzi, KRaft), Cassandra (cass-operator).
# The CRs are rendered by the local chart charts/datastores with helm-values/dc1-core/datastores.yaml.
locals {
  datastores_chart = "${path.module}/../charts/datastores"
  # Local chart changes don't bump a chart version, so feed a content hash in as a
  # value to make Terraform detect template edits.
  datastores_chart_checksum = sha1(join("", [
    for f in sort(fileset(local.datastores_chart, "**")) : filesha1("${local.datastores_chart}/${f}")
  ]))
}

# CloudNativePG expects basic-auth Secrets whose username matches the role.
resource "kubernetes_secret_v1" "dc1_pg_role" {
  for_each = toset(["ecommerce", "keycloak"])

  metadata {
    name      = "pg-dc1-${each.key}"
    namespace = module.dc1.name
    labels    = { "cnpg.io/reload" = "true" }
  }
  type = "kubernetes.io/basic-auth"
  data = {
    username = each.key
    password = var.datastore_passwords["dc1_pg_${each.key}"]
  }
}

# Kept even when enable_cassandra = false: cass-operator reads this Secret to process
# the CassandraDatacenter finalizer. Deleting both together left the CR stuck in deletion
# ("could not load superuser secret", 2026-09-18).
resource "kubernetes_secret_v1" "dc1_cassandra_superuser" {

  metadata {
    name      = "cassandra-dc1-superuser"
    namespace = module.dc1.name
  }
  data = {
    username = "dc1_admin"
    password = var.datastore_passwords["dc1_cassandra_superuser"]
  }

  # cass-operator marks the Secrets it watches; without this, every apply strips
  # the markers and the operator stops tracking password changes.
  lifecycle {
    ignore_changes = [
      metadata[0].annotations["cassandra.datastax.com/watched-by"],
      metadata[0].labels["cassandra.datastax.com/watched"],
    ]
  }
}

resource "helm_release" "dc1_datastores" {
  name      = "datastores"
  chart     = local.datastores_chart
  namespace = module.dc1.name

  values = [
    file("${local.values_dir}/dc1-core/datastores.yaml"),
    yamlencode({
      cassandra     = { enabled = var.enable_cassandra }
      kafka         = { enabled = var.enable_kafka }
      kafkaConnect  = { enabled = var.enable_cdc && var.enable_kafka }
      postgres      = { instances = var.dc1_pg_instances }
      metrics       = { enabled = var.enable_observability }
      chartChecksum = local.datastores_chart_checksum
    }),
  ]
  timeout = 600

  depends_on = [
    helm_release.strimzi,
    helm_release.cloudnative_pg,
    helm_release.cass_operator,
    kubernetes_secret_v1.dc1_pg_role,
    kubernetes_secret_v1.dc1_cassandra_superuser,
    kubernetes_network_policy_v1.cross_namespace,
  ]
}
