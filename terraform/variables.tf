variable "kubeconfig_path" {
  description = "Kubeconfig written by `k3d kubeconfig merge`."
  type        = string
  default     = "~/.kube/config"
}

variable "kube_context" {
  description = "kubectl context of the target k3d cluster (k3d names it k3d-<cluster>)."
  type        = string
  default     = "k3d-multidc"
}

variable "dc_nodes" {
  description = "Simulated DC id => k3d agent node name (see k3d/multidc-cluster.yaml)."
  type        = map(string)
  default = {
    dc1 = "k3d-multidc-agent-0"
    dc2 = "k3d-multidc-agent-1"
  }
}

variable "dc_quotas" {
  description = "ResourceQuota per DC namespace. Sized for a 4 CPU / 15 GiB host; see docs/topology.md."
  type = map(object({
    requests_cpu    = string
    requests_memory = string
    limits_cpu      = string
    limits_memory   = string
    pods            = number
    pvcs            = number
    storage         = string
  }))
  default = {
    # Phase 3 adds 7 services, Keycloak, APISIX and Kafka Connect (+ build pod).
    dc1 = {
      requests_cpu    = "4"
      requests_memory = "9Gi"
      limits_cpu      = "16"
      limits_memory   = "16Gi"
      pods            = 40
      pvcs            = 10
      storage         = "40Gi"
    }
    # Phase 4: PostgreSQL, Kafka + MM2 + Connect (+ build), Elasticsearch, MongoDB,
    # RabbitMQ, RustFS, Mailpit and six services.
    dc2 = {
      requests_cpu    = "8"
      requests_memory = "20Gi"
      limits_cpu      = "32"
      limits_memory   = "32Gi"
      pods            = 60
      pvcs            = 20
      storage         = "100Gi"
    }
  }
}

variable "container_defaults" {
  description = "LimitRange defaults applied to containers that omit requests/limits."
  type = object({
    request_cpu    = string
    request_memory = string
    limit_cpu      = string
    limit_memory   = string
  })
  default = {
    request_cpu    = "100m"
    request_memory = "256Mi"
    limit_cpu      = "1"
    limit_memory   = "512Mi"
  }
}

variable "chart_versions" {
  description = "Pinned operator chart versions (checked against the chart indexes on 2026-09-15)."
  type = object({
    strimzi                = string
    cloudnative_pg         = string
    cass_operator          = string
    keycloakx              = string
    apisix                 = string
    cert_manager           = string
    eck_operator           = string
    mongodb_kubernetes     = string
    rustfs                 = string
    mailpit                = string
    kube_prometheus_stack  = string
    fluent_bit             = string
    elasticsearch_exporter = string
    mongodb_exporter       = string
    chaos_mesh             = string
  })
  default = {
    strimzi                = "1.2.0"   # Strimzi 1.2.0, Kafka 4.3.1
    cloudnative_pg         = "0.29.0"  # CloudNativePG 1.30.0
    cass_operator          = "0.67.1"  # cass-operator 1.32.0
    keycloakx              = "7.3.1"   # Keycloak 26.7.3
    apisix                 = "2.17.0"  # APISIX 3.18.0
    cert_manager           = "v1.21.2" # checked 2026-09-18
    eck_operator           = "3.5.0"   # ECK 3.5.0
    mongodb_kubernetes     = "1.12.0"  # mongodb-kubernetes operator (MongoDB Community)
    rustfs                 = "1.0.0"   # RustFS 1.0.0
    mailpit                = "0.36.1"  # Mailpit 1.29.6
    kube_prometheus_stack  = "91.4.1"  # Prometheus Operator v0.94.0
    fluent_bit             = "0.58.2"  # Fluent Bit 5.1.2
    elasticsearch_exporter = "7.4.0"
    mongodb_exporter       = "3.22.0"
    chaos_mesh             = "2.8.4"
  }
}

variable "external_client_cidr" {
  description = "Subnet of the k3d Docker network; external clients reach APISIX from here. Check: docker network inspect k3d-multidc --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}'"
  type        = string
  default     = "172.25.0.0/16"
}

variable "enable_cassandra" {
  description = "Cassandra is the largest DC1 store (~1.5 GiB). Set false to free memory, e.g. during Phase 3."
  type        = bool
  default     = true
}

variable "enable_observability" {
  description = "Phase 6: kube-prometheus-stack (Prometheus, Alertmanager, Grafana), monitors and dashboards, Fluent Bit -> Elasticsearch/Kibana logging, Icinga uptime checks."
  type        = bool
  default     = true
}

variable "enable_chaos" {
  description = "Phase 7: Chaos Mesh (experiments in chaos/experiments, run by scripts/chaos-demo.sh)."
  type        = bool
  default     = true
}

variable "dc1_pg_instances" {
  description = "pg-dc1 instances. 2 = primary + streaming replica, so killing the primary shows a real failover (Phase 7)."
  type        = number
  default     = 2
}

variable "enable_dc2" {
  description = "Phase 4 analytics DC: DC2 stores (PostgreSQL, Kafka + MirrorMaker 2 + Connect, Elasticsearch, MongoDB, RabbitMQ, RustFS, Mailpit), their operators and the six DC2 services."
  type        = bool
  default     = true
}

variable "enable_kafka" {
  description = "Kafka broker + entity operator (~820 MiB). Off in the minimal profile: the token -> cart -> order test doesn't use Kafka. Kafka Connect needs it."
  type        = bool
  default     = true
}

variable "dc1_services" {
  description = "DC1 services to deploy. null = every entry in helm-values/dc1-core/services.yaml not marked `enabled: false`."
  type        = list(string)
  default     = null
}

variable "enable_cdc" {
  description = "Kafka Connect + Debezium (~800 MiB). Required for the Phase 3 order-event check and Phase 4 search indexing."
  type        = bool
  default     = true
}

variable "datastore_passwords" {
  description = "Data-store and Keycloak admin passwords, generated by `make secrets` (ansible/playbooks/bootstrap-secrets.yml) into terraform/secrets.auto.tfvars.json."
  type        = map(string)
  sensitive   = true
}

variable "enable_data_tools" {
  description = "Phase 4.5: data-tools release in dc1-core (seed-products Job; seed-orders and loadgen per their own toggles). Needs `make data-tools-image` and `make keycloak-config` first (docs/data-layer.md)."
  type        = bool
  default     = true
}

variable "enable_seed_orders" {
  description = "Phase 4.5: Olist replay Job. Also needs data-tools/data/olist-replay.jsonl.gz (`make olist-prepare`); without the file the Job is skipped."
  type        = bool
  default     = true
}

variable "enable_loadgen" {
  description = "Phase 4.5: continuous traffic generator with labelled fraud patterns (helm-values/dc1-core/data-tools.yaml)."
  type        = bool
  default     = true
}
