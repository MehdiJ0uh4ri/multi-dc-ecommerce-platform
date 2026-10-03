# Every cross-namespace path into a DC namespace. Everything else is blocked by each
# namespace's default-deny-ingress policy (modules/dc-namespace). Terraform is the only
# owner of NetworkPolicies: Strimzi's own generation is disabled (ADR-012).
#
# Workloads opt in with the pod label `platform.local/role=<role>`; charts set it
# (charts/datastores, charts/spring-service, helm-values/*). Contract: docs/topology.md.
# Each path: target_labels (pods receiving), source = from_namespace + from_labels
# ({} = any pod there) or from_cidr. `name` is the policy name when the map key differs
# (same policy name in both DC namespaces).
locals {
  role_label = "platform.local/role"
  app_label  = "app.kubernetes.io/name"

  dc1_paths = {
    # --- DC <-> DC -----------------------------------------------------------
    # MirrorMaker 2 runs in DC2 and pulls topics from DC1.
    "allow-dc2-replicator-to-kafka" = {
      name           = null
      namespace      = module.dc1.name
      target_labels  = { (local.role_label) = "kafka-broker" }
      from_namespace = module.dc2.name
      from_labels    = { (local.role_label) = "kafka-replicator" }
      from_cidr      = null
      ports          = [9092]
    }
    # DC2 services validate JWTs against Keycloak (JWT_ISSUER_URI / JWKS), which lives in DC1.
    "allow-dc2-services-to-keycloak" = {
      name           = null
      namespace      = module.dc1.name
      target_labels  = { (local.role_label) = "keycloak" }
      from_namespace = module.dc2.name
      from_labels    = { (local.role_label) = "api-service" }
      from_cidr      = null
      ports          = [8080]
    }
    # APISIX in DC1 routes to DC2 services. Ports from app/k8s/backend/*.yaml:
    # favourite 8081, media 8083, rating 8089, notification 8090, promotion 8093, search 8094.
    "allow-dc1-gateway-to-services" = {
      name           = null
      namespace      = module.dc2.name
      target_labels  = { (local.role_label) = "api-service" }
      from_namespace = module.dc1.name
      from_labels    = { (local.role_label) = "api-gateway" }
      from_cidr      = null
      ports          = [8081, 8083, 8089, 8090, 8093, 8094]
    }

    # --- External traffic -----------------------------------------------------
    # Clients reach APISIX through the k3d load balancer. The apisix-external Service uses
    # externalTrafficPolicy=Local, so the source stays an address on the k3d network.
    "allow-external-to-gateway" = {
      name           = null
      namespace      = module.dc1.name
      target_labels  = { (local.role_label) = "api-gateway" }
      from_namespace = null
      from_labels    = {}
      from_cidr      = var.external_client_cidr
      ports          = [9080]
    }

    # --- Operators -> DC1 data stores -----------------------------------------
    # Strimzi cluster operator: control plane 9090, replication 9091, KafkaAgent 8443
    # (KafkaCluster.java, Strimzi 1.2.0).
    "allow-operators-to-kafka" = {
      name           = null
      namespace      = module.dc1.name
      target_labels  = { (local.role_label) = "kafka-broker" }
      from_namespace = local.operators_namespace
      from_labels    = {}
      from_cidr      = null
      ports          = [9090, 9091, 8443]
    }
    # Strimzi cluster operator manages KafkaConnectors through the Connect REST API.
    "allow-operators-to-kafka-connect" = {
      name           = null
      namespace      = module.dc1.name
      target_labels  = { (local.role_label) = "kafka-connect" }
      from_namespace = local.operators_namespace
      from_labels    = {}
      from_cidr      = null
      ports          = [8083]
    }
    # CloudNativePG operator: instance manager status 8000 and PostgreSQL 5432 (docs/src/networking.md).
    "allow-operators-to-postgres" = {
      name           = null
      namespace      = module.dc1.name
      target_labels  = { (local.role_label) = "postgres" }
      from_namespace = local.operators_namespace
      from_labels    = {}
      from_cidr      = null
      ports          = [8000, 5432]
    }
    # cass-operator: management API 8080 (DefaultMgmtApiPort).
    "allow-operators-to-cassandra" = {
      name           = null
      namespace      = module.dc1.name
      target_labels  = { (local.role_label) = "cassandra" }
      from_namespace = local.operators_namespace
      from_labels    = {}
      from_cidr      = null
      ports          = [8080]
    }
  }

  # Phase 4 paths, only with var.enable_dc2.
  dc2_paths = {
    # search-service indexes products by fetching them from product-service in DC1
    # (ServiceUrlConfig ecommerce.services.product). Scoped to exactly those two apps.
    "allow-dc2-search-to-product" = {
      name           = null
      namespace      = module.dc1.name
      target_labels  = { (local.app_label) = "product-service" }
      from_namespace = module.dc2.name
      from_labels    = { (local.app_label) = "search-service" }
      from_cidr      = null
      ports          = [8086]
    }
    "allow-operators-to-kafka@dc2" = {
      name           = "allow-operators-to-kafka"
      namespace      = module.dc2.name
      target_labels  = { (local.role_label) = "kafka-broker" }
      from_namespace = local.operators_namespace
      from_labels    = {}
      from_cidr      = null
      ports          = [9090, 9091, 8443]
    }
    "allow-operators-to-kafka-connect@dc2" = {
      name           = "allow-operators-to-kafka-connect"
      namespace      = module.dc2.name
      target_labels  = { (local.role_label) = "kafka-connect" }
      from_namespace = local.operators_namespace
      from_labels    = {}
      from_cidr      = null
      ports          = [8083]
    }
    # MirrorMaker 2 is a Connect cluster: Strimzi manages its connectors over REST.
    "allow-operators-to-mirrormaker2" = {
      name           = null
      namespace      = module.dc2.name
      target_labels  = { (local.role_label) = "kafka-replicator" }
      from_namespace = local.operators_namespace
      from_labels    = {}
      from_cidr      = null
      ports          = [8083]
    }
    "allow-operators-to-postgres@dc2" = {
      name           = "allow-operators-to-postgres"
      namespace      = module.dc2.name
      target_labels  = { (local.role_label) = "postgres" }
      from_namespace = local.operators_namespace
      from_labels    = {}
      from_cidr      = null
      ports          = [8000, 5432]
    }
    # ECK operator manages the cluster through the Elasticsearch HTTP API.
    "allow-operators-to-elasticsearch" = {
      name           = null
      namespace      = module.dc2.name
      target_labels  = { (local.role_label) = "elasticsearch" }
      from_namespace = local.operators_namespace
      from_labels    = {}
      from_cidr      = null
      ports          = [9200]
    }
    "allow-operators-to-mongodb" = {
      name           = null
      namespace      = module.dc2.name
      target_labels  = { (local.role_label) = "mongodb" }
      from_namespace = local.operators_namespace
      from_labels    = {}
      from_cidr      = null
      ports          = [27017]
    }
    # Messaging Topology Operator declares exchanges/queues/bindings via the management API.
    "allow-topology-operator-to-rabbitmq" = {
      name           = null
      namespace      = module.dc2.name
      target_labels  = { (local.role_label) = "rabbitmq" }
      from_namespace = local.rabbitmq_operators_namespace
      from_labels    = {}
      from_cidr      = null
      ports          = [15672]
    }
  }

  # Phase 6: Prometheus (metrics ports) and Icinga (service ports) in namespace monitoring;
  # Alertmanager/Icinga mail to Mailpit (25) in DC2.
  monitoring_paths = {
    "allow-monitoring@dc1" = {
      name           = "allow-monitoring"
      namespace      = module.dc1.name
      target_labels  = {}
      from_namespace = "monitoring"
      from_labels    = {}
      from_cidr      = null
      # 9000 Spring/Keycloak/Cassandra metrics, 9404 Strimzi JMX exporter, 9187 CNPG,
      # 9091 APISIX, 8080 entity operator + Keycloak, then Icinga probes.
      ports = [9000, 9404, 9187, 9091, 8080, 5432, 9092, 9042, 9080, 8083]
    }
    "allow-monitoring@dc2" = {
      name           = "allow-monitoring"
      namespace      = module.dc2.name
      target_labels  = {}
      from_namespace = "monitoring"
      from_labels    = {}
      from_cidr      = null
      # 15692 RabbitMQ, 9108 Elasticsearch exporter, 9216 MongoDB exporter, 25 Mailpit.
      ports = [9000, 9404, 9187, 15692, 9108, 9216, 8080, 5432, 9092, 9200, 27017, 5672, 8083, 25]
    }
  }

  cross_namespace_paths = merge(
    local.dc1_paths,
    { for k, v in local.dc2_paths : k => v if var.enable_dc2 },
    { for k, v in local.monitoring_paths : k => v if var.enable_observability && (v.namespace == module.dc1.name || var.enable_dc2) },
  )
}

moved {
  from = kubernetes_network_policy_v1.cross_dc
  to   = kubernetes_network_policy_v1.cross_namespace
}

resource "kubernetes_network_policy_v1" "cross_namespace" {
  for_each = local.cross_namespace_paths

  metadata {
    name      = coalesce(each.value.name, each.key)
    namespace = each.value.namespace
  }
  spec {
    pod_selector {
      match_labels = each.value.target_labels
    }
    policy_types = ["Ingress"]
    ingress {
      from {
        # namespace_selector and pod_selector in the same `from` entry are ANDed.
        dynamic "namespace_selector" {
          for_each = each.value.from_cidr == null ? [each.value.from_namespace] : []
          content {
            match_labels = { "kubernetes.io/metadata.name" = namespace_selector.value }
          }
        }
        dynamic "pod_selector" {
          for_each = each.value.from_cidr == null && length(each.value.from_labels) > 0 ? [each.value.from_labels] : []
          content {
            match_labels = pod_selector.value
          }
        }
        dynamic "ip_block" {
          for_each = each.value.from_cidr == null ? [] : [each.value.from_cidr]
          content {
            cidr = ip_block.value
          }
        }
      }
      dynamic "ports" {
        for_each = each.value.ports
        content {
          port     = ports.value
          protocol = "TCP"
        }
      }
    }
  }
}
