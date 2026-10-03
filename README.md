# multi-dc-platform

A production-style data and infrastructure platform on a local k3d cluster. Two Kubernetes namespaces play the part of two datacenters: `dc1-core` handles transactions and `dc2-analytics` handles analytics and reads. The application layer is [hoangtien2k3/ecommerce-microservices](https://github.com/hoangtien2k3/ecommerce-microservices), vendored as a submodule under `app/`.

| Dir            | Owns                                                                    |
|----------------|-------------------------------------------------------------------------|
| `terraform/`   | Every Kubernetes object and Helm release (providers use the k3d kubeconfig) |
| `ansible/`     | Anything outside Kubernetes: tool bootstrap, values templating, secrets, CI runner |
| `helm-values/` | Values files per simulated DC (`dc1-core/`, `dc2-analytics/`) and `platform-operators/` |
| `charts/`      | Local charts: operator CRs per DC (`datastores`), `spring-service`, `data-tools`, `observability`, `icinga` |
| `data-tools/`  | Seeders and load generator (Python image, Phase 4.5, `docs/data-layer.md`) |
| `ci/`          | Pipeline definitions (Phase 5)                                          |
| `monitoring/`  | Dashboards, alert rules, Icinga config (Phase 6)                        |
| `k3d/`         | Cluster definition                                                      |
| `docs/`        | Decisions, findings about the upstream app, architecture                |
| `app/`         | Upstream app (git submodule, pinned)                                    |

## Phase status

| Phase | Scope                               | Status  |
|-------|-------------------------------------|---------|
| 0     | Scaffolding, submodule, TF providers | done |
| 1     | Namespaces, quotas, NetworkPolicies, DC node topology | done (`make verify-phase1`) |
| 2     | DC1 PostgreSQL, Kafka, Cassandra via operators | done (`make verify-phase2`) |
| 3     | DC1 services, Keycloak, APISIX, Debezium order events | done (minimal profile, `make verify-phase3`) |
| 4     | DC2: Kafka + MirrorMaker 2, Elasticsearch, MongoDB, RabbitMQ, RustFS, PostgreSQL, six services, Kafka sinks | written, not applied |
| 4.5   | Data layer: DummyJSON catalogue + Olist replay through APISIX, loadgen with labelled fraud patterns, `order-context` topic (`docs/data-layer.md`) | written, unit-tested offline, not applied |
| 5     | CI/CD                                | not started |
| 6     | Prometheus/Grafana/Alertmanager, Fluent Bit → Elasticsearch/Kibana, Icinga (`docs/observability.md`) | written, not applied |
| 7     | Chaos Mesh experiments + `scripts/chaos-demo.sh` (`docs/chaos-runbook.md`) | written, not applied |

## Quick start (Phase 0)

```bash
make tools            # install terraform/kubectl/helm/k3d into ~/.local/bin
make check-tools
make app-init
make tf-init tf-validate
make ansible-check
```

Read `docs/decisions.md` before creating the cluster.
