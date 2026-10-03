# Architecture (target — not yet built)

Everything below is the **intended** end state. Only Phase 0 scaffolding exists in the repo.

```mermaid
flowchart LR
  subgraph DC1["dc1-core (agent-0)"]
    GW[APISIX + Keycloak] --> SVC1[auth/product/order/payment/inventory/tax/shipping]
    SVC1 --> PG[(PostgreSQL)]
    SVC1 --> K1[(Kafka)]
  end
  subgraph DC2["dc2-analytics (agent-1)"]
    BR[MM2 or bridge] --> SVC2[search/rating/favourite/promotion/media/notification]
    SVC2 --> ES[(Elasticsearch)]
    SVC2 --> MG[(MongoDB)]
    SVC2 --> RMQ[(RabbitMQ)]
    SVC2 --> S3[(MinIO)]
  end
  K1 -- "only allowed cross-DC path(s)" --> BR
```

| Phase | Adds |
|-------|------|
| 1 | Namespaces, ResourceQuotas, NetworkPolicies (default-deny plus explicit replication paths), node labels and taints |
| 2 | Operators in `platform-operators`; PostgreSQL (CloudNativePG), single-node KRaft Kafka (Strimzi), Cassandra (cass-operator) in `dc1-core` |
| 3 | DC1 services (charts/spring-service), APISIX standalone, Keycloak (keycloakx), Debezium CDC on orders; end-to-end order test |
| 4 | DC2: kafka-dc2 + MirrorMaker 2 (identity), connect-dc2 sinks (MongoDB, RabbitMQ), Elasticsearch (ECK), MongoDB (mongodb-kubernetes), RabbitMQ (Cluster + Topology Operators), RustFS, pg-dc2, Mailpit, six services; product CDC + Cassandra sink in DC1; cert-manager |
| 5 | CI server and pipeline → k3d registry → Helm release |
| 6 | kube-prometheus-stack + monitors/rules (charts/observability) + exporters, dashboards (monitoring/grafana-dashboards), Fluent Bit → ECK Elasticsearch/Kibana, Icinga (charts/icinga) with Alertmanager/Icinga mail to Mailpit |
| 7 | Chaos Mesh; experiments: Kafka broker kill, PostgreSQL primary failover (2 instances), DC1↔DC2 partition, cross-DC latency; scripts/chaos-demo.sh reports degradation, recovery and downstream consistency |

Open questions that affect this design are listed in `docs/upstream-app-findings.md`.
