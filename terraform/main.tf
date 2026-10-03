# Connectivity check. Resources live in topology.tf, namespaces.tf, network-policies.tf.
data "kubernetes_server_version" "this" {}
