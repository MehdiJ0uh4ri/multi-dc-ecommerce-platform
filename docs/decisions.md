# Decisions

Status values: **accepted** (implemented in the repo) or **proposed** (waiting for owner confirmation).

## ADR-001 — Target cluster: new `multidc` cluster (accepted 2026-09-15)

The existing cluster `petclinic` has **1 server, 0 agents and no registry**. This was checked with `docker ps -a` and the k3d labels on `k3d-petclinic-server-0`. Its API was advertised on 172.17.0.1:6551, and it was stopped when this was checked. There is also no `~/.kube/config` on the host yet.

With a single node there is nothing to label or taint as DC1 vs DC2, and there is no registry for Phase 5 to push to.

Proposal: `k3d/multidc-cluster.yaml` defines 1 server, 2 agents (one per simulated DC) and `k3d-registry.localhost:5000`. Phase 1 labels the agents in Terraform.

Alternative: keep using `petclinic` by setting `kube_context = "k3d-petclinic"`. Everything still works, except that DC node affinity has no effect and a registry must be added separately.

## ADR-002 — Terraform state: local backend (accepted)

The `kubernetes` backend keeps state in a Secret inside the cluster Terraform manages. Deleting or recreating the cluster, which is routine with k3d, would lose that state. Local state under `terraform/state/` is gitignored and survives cluster rebuilds.

## ADR-003 — App as a submodule pinned to upstream commit `394b34b` (accepted)

The submodule points at upstream. Nobody has forked it yet, and forking needs your GitHub account. To use a fork later, run `git submodule set-url app <fork-url>`.

## ADR-004 — Tool ownership boundary (accepted)

Terraform owns every Kubernetes object and Helm release, through the `kubernetes` ~>3.2 and `helm` ~>3.3 providers. Ansible never applies Kubernetes objects. It renders inputs for Terraform (values files, secrets) and sets up hosts and runners.

## ADR-005 — Ceph vs MinIO (accepted 2026-09-15: MinIO; superseded by ADR-016)

The app already speaks S3: `common-storage` uses AWS SDK v2, and upstream uses RustFS. Rook-Ceph on k3d needs raw block devices or loop devices inside Docker containers, plus about 3 OSDs and a MON/MGR set. That is several GB of RAM, and 6 GiB was free on this host. MinIO provides the same S3 API as a single pod but none of Ceph's operations model (CRUSH, OSD failure, RBD/CephFS). Recommendation: MinIO, and document the gap.

## ADR-006 — DC2 gets its own PostgreSQL (accepted 2026-09-15)

rating, favourite, promotion and media need PostgreSQL. A separate instance in `dc2-analytics` keeps the DC boundary real: no database traffic crosses namespaces, and the only cross-DC paths are the ones listed in `docs/topology.md`. It costs one extra small Postgres pod.

## ADR-007 — MongoDB, Cassandra and RabbitMQ are fed from Kafka (accepted 2026-09-15)

No upstream service uses them (see `docs/upstream-app-findings.md`). They get real data through Kafka-driven pipelines built in Phases 2 and 4, for example Kafka Connect sinks and a Kafka→RabbitMQ bridge, so they are not idle installs. The exact connectors are chosen in those phases. RAM is the constraint, so each store runs as a single small replica.

## ADR-008 — Pin DC workloads with namespace admission plugins (accepted)

The PodNodeSelector and PodTolerationRestriction namespace annotations pin every pod in a DC namespace, instead of repeating `nodeSelector`/`tolerations` in every Helm values file. It is one mechanism, set once per namespace. Trade-off: both plugins are long-standing but still use `alpha`-named annotations, and they must be enabled on the k3s apiserver. Details and fallback: `docs/topology.md`.

## ADR-009 — Ingress-only NetworkPolicies (accepted)

Each DC namespace has default-deny ingress plus explicit cross-DC allows keyed on a `platform.local/role` pod label. Egress is not restricted. Default-deny egress would also require allow rules for CoreDNS and the k3s API server endpoint, adding moving parts without blocking any extra cross-DC path, because the receiving side already drops traffic. k3s enforces NetworkPolicy with its embedded kube-router controller.

## ADR-010 — Data stores run through operators, not Bitnami charts (accepted 2026-09-15)

On 2026-09-15, `bitnami/kafka` and `bitnami/cassandra` had no tags on Docker Hub, and `bitnami/postgresql` only had digest/`latest` builds. The `bitnamilegacy/*` images were last updated in August 2025 and receive no patches. Bitnami charts would therefore run unpatched images.

| Store      | Operator (Helm chart)                            | Why                                                                 |
|------------|--------------------------------------------------|---------------------------------------------------------------------|
| PostgreSQL | CloudNativePG 1.30.0 (`cloudnative-pg` 0.29.0)   | Declarative `Database` and roles; manages its own webhook certificates |
| Kafka      | Strimzi 1.2.0, Kafka 4.3.1 KRaft                 | Same operator provides `KafkaMirrorMaker2` (Phase 4) and `KafkaConnect` (ADR-007 sinks) |
| Cassandra  | cass-operator 1.32.0 (`cass-operator` 0.67.1)    | Much lighter than k8ssandra-operator                                |

- **Namespace:** operators run in `platform-operators`, on the untainted server node.
- **CRs:** they are rendered by the local chart `charts/datastores`, which Terraform installs with `helm_release`. With `kubernetes_manifest`, planning fails before the operators' CRDs exist. Using a chart avoids that.
- **cass-operator webhooks are disabled.** Enabling them requires cert-manager, which is another ~300 MiB on a host with about 5.7 GiB free. The cost is no admission-time validation of `CassandraDatacenter` specs; errors surface in the operator logs instead.

## ADR-011 — Data-store passwords: Ansible generates, Terraform applies (accepted 2026-09-15)

`make secrets` runs `ansible/playbooks/bootstrap-secrets.yml`. It creates one random password per key in `ansible/.secrets/`, and re-runs reuse the existing files. It then renders `terraform/secrets.auto.tfvars.json`. Terraform creates the Kubernetes Secrets from that file.

This follows ADR-004: Ansible prepares inputs and Terraform owns Kubernetes objects. Trade-off: the passwords are also stored in plaintext in the local Terraform state. The state, the tfvars file and `.secrets/` are all gitignored and never leave the machine.

## ADR-012 — Terraform is the only owner of NetworkPolicies (accepted 2026-09-15)

Strimzi generates its own NetworkPolicy by default. Its client listeners are open to all namespaces unless `networkPolicyPeers` is set (`KafkaCluster.java` and the CRD reference, Strimzi 1.2.0). Keeping that would put the cross-DC contract in two places.

Instead, `STRIMZI_NETWORK_POLICY_GENERATION=false` is set on the operator, and `terraform/network-policies.tf` declares every path, including operator-to-store traffic:
- Strimzi: ports 9090, 9091 and 8443
- CloudNativePG: ports 8000 and 5432
- cass-operator: port 8080

## ADR-013 — Gateway and identity: APISIX standalone plus keycloakx (accepted 2026-09-15)

**APISIX.** The official `apisix` chart 2.17.0 (APISIX 3.18.0) runs in `standalone` mode. It loads the upstream routes file `app/deploy/apisix/apisix.yaml` from a ConfigMap and runs without etcd or the Admin API.

- **Alternative considered:** upstream Kubernetes uses the APISIX ingress controller with `ApisixRoute` CRDs, which needs etcd and the controller (several hundred MiB).
- **Routes file:** used unchanged apart from the client-secret placeholder. The client is public, and tokens are validated via JWKS.
- **Exposure:** `LoadBalancer` Service with `externalTrafficPolicy: Local`, reached at `http://localhost:8080`. With `Cluster`, kube-proxy SNATs external traffic to a node address, and the NetworkPolicy refused it. `Local` keeps the k3d-network source address, which `allow-external-to-gateway` admits by ipBlock. Details: `docs/topology.md`.

**Keycloak.** codecentric `keycloakx` 7.3.1 (Keycloak 26.7.3) runs in production `start` mode on `pg-dc1`, importing the upstream realm.

- **Issuer:** `--hostname=http://keycloak.dc1-core.svc.cluster.local:8080` makes it identical for every client. DC2 services will validate against the same URL.
- **Service alias:** Terraform adds a Service named `keycloak` on port 8080, because the upstream routes expect `http://keycloak:8080`.

## ADR-014 — Order events via Debezium CDC (accepted 2026-09-15)

order-service has no Kafka producer. The app's own design uses Debezium change events instead: search-service consumes `dbproduct.public.product` and reads the Debezium `op` field.

Setup:
- A Strimzi `KafkaConnect` builds an image with the Debezium Postgres connector 3.6.2.Final, sha512-pinned, and pushes it to `registry.localhost:5000`.
- The `orders-cdc` connector streams `orderservice.public.orders` to `dborder.public.orders`.
- Converters are schema-less JSON, matching what search-service parses.

Trade-offs:
- **Replication rights:** Debezium connects as the `ecommerce` table owner, which is given `REPLICATION`. That is simpler than a dedicated role with per-table grants on tables Hibernate creates at runtime, but broader.
- **Memory:** Connect costs about 800 MiB. It can be turned off with `enable_cdc = false`.


## ADR-015 — cert-manager as a platform component (accepted 2026-09-18)

The RabbitMQ Cluster and Messaging Topology Operator manifests (v2.23.0 and v1.20.3) ship `Issuer` and `Certificate` objects for their admission webhooks, so cert-manager v1.21.2 is installed in its own namespace. With cert-manager present, cass-operator's admission webhooks are switched back on; they were disabled only for lack of cert-manager (ADR-010).

## ADR-016 — RustFS replaces MinIO for S3 storage (accepted 2026-09-18, supersedes ADR-005)

On 2026-09-18, `minio/minio` and `minio/operator` were archived on GitHub. The last server release was `RELEASE.2025-10-15T17-29-55Z` and the operator's was v7.1.1 (2025-04). RustFS 1.0.0 (2026-09-16) is maintained, has an official Helm chart, and is what the upstream app itself uses (`k8s/infra/rustfs.yaml`).

It runs in standalone mode in `dc2-analytics`. media-service uses it through its S3 settings (path-style, bucket auto-created by `common-storage`). The Ceph trade-off from ADR-005 still applies.

## ADR-017 — Elasticsearch via ECK, version 8.19 (accepted 2026-09-18)

Elastic's operator ECK 3.5.0 manages `es-dc2`, and will also serve Kibana for Phase 6. Elasticsearch runs **8.19.21**, not 9.x, because search-service is built with the Elasticsearch 8.15 Java client.

- HTTP TLS is disabled for in-cluster use, while authentication stays on. search-service reads the `elastic` password from `es-dc2-es-elastic-user`.
- `node.store.allow_mmap: false` avoids the `vm.max_map_count` host sysctl on k3d nodes.

## ADR-018 — MongoDB Community via mongodb-kubernetes (accepted 2026-09-18)

The former `mongodb-kubernetes-operator` repository is archived. Its successor, `mongodb-kubernetes` 1.12.0, runs with `watchNamespace=dc2-analytics` and only watches `mongodbcommunity` resources.

- `mongo-dc2` is a 1-member replica set on MongoDB 8.0.32 with SCRAM authentication.
- The operator writes the `analytics` user's connection string to `mongo-dc2-admin-analytics` (`connectionString.standard`).

## ADR-019 — RabbitMQ Cluster + Messaging Topology Operators, vendored manifests (accepted 2026-09-18)

RabbitMQ publishes plain release manifests and no Helm chart. The v2.23.0 and v1.20.3 files are vendored unmodified under `charts/vendor/`, with their sha256 recorded in each `Chart.yaml`, so Terraform installs them like every other operator.

Exchanges, queues and bindings are declared as `Exchange`/`Queue`/`Binding` resources, not with ad-hoc `rabbitmqadmin` calls. The Topology Operator reaches the RabbitMQ management API on port 15672 through `allow-topology-operator-to-rabbitmq`.

## ADR-020 — MirrorMaker 2 with identity replication, running in DC2 (accepted 2026-09-18)

`mm2-dc1-to-dc2` runs next to its target, `kafka-dc2`, and pulls from `kafka-dc1`. Its pods carry `role=kafka-replicator`, the only DC2 role admitted to DC1's Kafka.

- **Replication policy:** `IdentityReplicationPolicy` keeps topic names unchanged, so DC2 consumers use DC1 names. search-service hard-codes `dbproduct.public.product`.
- **Topics:** only the business topics are mirrored: Debezium CDC (`dbproduct.*`, `dborder.*`) and the app's payment and profile events.

This replaces the one-cluster alternative of DC2 consumers reading DC1's Kafka directly. That option was cheaper, but it would not exercise real cross-DC replication.

## ADR-021 — Product CDC mapped onto search-service's contract (accepted 2026-09-18)

The upstream schema is table `products` with key column `product_id`. search-service's `ProductSyncDataConsumer` listens on `dbproduct.public.product` and reads key field `id`. The `products-cdc` Debezium connector bridges both differences with standard Kafka Connect SMTs, without changing any app code:
- `RegexRouter` renames the topic.
- `ReplaceField$Key` renames `product_id` to `id`.

Every Debezium connector also sets `decimal.handling.mode=double`. With schema-less JSON, the default (`precise`) emits NUMERIC columns such as `orders.order_fee` as base64 bytes, which the MongoDB and Cassandra sinks cannot use.

## ADR-022 — Kafka-fed MongoDB, Cassandra and RabbitMQ (accepted 2026-09-18, implements ADR-007)

| Sink | Where | Plugin | From → to |
|---|---|---|---|
| MongoDB | connect-dc2 | mongo-kafka-connect 3.1.0 (Debezium Postgres CDC handler) | `dborder.public.orders` → `analytics.orders`; `dbproduct.public.product` → `analytics.products` |
| RabbitMQ | connect-dc2 | Camel spring-rabbitmq sink 4.18.0 | `SUCCESSFUL` (the only payment topic payment-service produces) → exchange `payments` → queue `payments.audit` |
| Cassandra | connect-dc1 | DataStax kafka-sink 1.7.6 | `dborder.public.orders` → `ecommerce.orders_by_id` (keyspace and table created by a CQL Job) |

Plugins are fetched by Strimzi builds, and each is pinned by sha512. The Cassandra sink renames the dotted topic first, because DataStax mapping keys use `topic.<topic>.<ks>.<table>`. It then extracts Debezium's `after` row image. notification-service sends mail to Mailpit in DC2 instead of `smtp.gmail.com`.


## ADR-023 — Metrics: kube-prometheus-stack plus hand-written monitors (accepted 2026-09-18)

kube-prometheus-stack 91.4.1 runs in `monitoring` with every `*SelectorNilUsesHelmValues` set to false, so Prometheus picks up monitors from any namespace and any release.

- **Monitors for components without one:** `charts/observability` defines them.
  - Strimzi pods (the upstream example PodMonitors) and Kafka Exporter for consumer lag
  - CloudNativePG (a hand-written PodMonitor, as its docs recommend)
  - Cassandra (management API `/metrics`), RabbitMQ (the upstream ServiceMonitor), and every Spring service
- **Components with their own switch:** APISIX, Keycloak and the exporters use their chart's ServiceMonitor option.
- **Disabled:** kube-etcd, controller-manager, scheduler and proxy scraping, because k3s embeds them.
- **Tainted DC nodes:** node-exporter tolerates them.

## ADR-024 — Dashboards as files (accepted 2026-09-18)

`monitoring/grafana-dashboards/*.json` become ConfigMaps labelled `grafana_dashboard=1` in the Grafana "Platform" folder. They are:
- the Strimzi 1.2.0 upstream dashboards and the CloudNativePG dashboard, unmodified apart from dropping the `__inputs` import stanza
- one platform dashboard with request rate and p95 per service, DB connections and Kafka lag

The p95 latency relies on Micrometer histogram buckets, switched on by environment variable. No app change is needed.

## ADR-025 — Logs: Fluent Bit to a separate ECK Elasticsearch (accepted 2026-09-18)

A Fluent Bit DaemonSet tolerates all taints and tails `/var/log/containers` on every node. It sends to `es-logs` (ECK 8.19.21, namespace `logging`), with Kibana. It uses the `k8s-*` index prefix and authenticates with the ECK-generated `elastic` user.

The log store is separate from DC2's search Elasticsearch, so log volume can never degrade product search.

## ADR-026 — Icinga: local chart instead of icinga-stack (accepted 2026-09-18)

The official `icinga-stack` 0.7.0 was rejected for two reasons:
- Its internal databases and Redis use `mariadb:latest` and `redis:latest`, with no value to pin them.
- Its Icinga 2 config is a ConfigMap with no hook for check definitions, so it expects Icinga Director.

`charts/icinga` follows the same patterns as the official subcharts:
- the bootstrap init container (`icinga2 daemon -C` with `ICINGA_MASTER=1`, which creates the API PKI) and the core config
- Icinga Web 2 configured through env vars

Its differences:
- pinned images: icinga2 2.16.5, icingadb 1.5.1, icingaweb2 2.14.0, valkey 9.0.6
- PostgreSQL from CloudNativePG (`pg-monitoring`)
- checks shipped as `conf.d/platform.conf`

Icinga DB (`--database-auto-import`) and Icinga Web 2 (its entrypoint) create their own schemas.

## ADR-027 — Alert delivery to Mailpit (accepted 2026-09-18)

Alertmanager (smtp) and Icinga (msmtp, which the icinga2 image ships) both mail `oncall@platform.local` through Mailpit in DC2, via `allow-monitoring@dc2` on port 25. With DC2 disabled, Alertmanager falls back to a null receiver.

## ADR-028 — Chaos Mesh with a namespace allow-list (accepted 2026-09-18)

Chaos Mesh 2.8.4 is configured for k3s's containerd socket (`/run/k3s/containerd/containerd.sock`). Its daemon tolerates the DC taints.

- **Allow-list:** `enableFilterNamespace` limits experiments to namespaces annotated `chaos-mesh.org/inject=enabled`, which only the DC namespaces are.
- **Experiments:** they live in `chaos/experiments/` and are applied only by `scripts/chaos-demo.sh`, which removes them on exit. Terraform never applies them.

## ADR-029 — pg-dc1 runs two instances (accepted 2026-09-18)

`dc1_pg_instances = 2`, a primary plus a streaming replica, so killing the primary demonstrates a real CloudNativePG failover rather than a restart. The minimal profile keeps one instance.

## ADR-030 — Platform-owned `order-context` topic for geography (accepted 2026-09-18)

The app records no geography (upstream finding #10), but the Phase 5a geo-mismatch rule needs shipping and billing countries. The data tools publish one `order-context` event per order they place, to kafka-dc1. The key is the orderId and the value carries the countries, userId, productId, orderFee and whether the account was just created. MirrorMaker 2 copies the topic to DC2 (`topicsPattern`).

The generator's intent (normal or a fraud pattern) travels only in the Kafka header `scenario`, as ground truth for measuring detection. Detectors must not read it.

Rejected alternatives:
- dropping the rule;
- patching order-service, which would need a code change and Phase 5 CI.

In production, this event would come from the checkout front end.

## ADR-031 — Keycloak objects in a separate Terraform root (accepted 2026-09-18)

The `keycloak/keycloak` provider (~> 5.9) calls the Keycloak admin API, which exists only after the main root module has deployed Keycloak. A provider cannot depend on a resource created in the same apply, so `terraform/keycloak/` is its own root with its own local state. `make keycloak-config` runs it through a `kubectl port-forward`.

It manages only the confidential client `platform-seeder`. That client has service accounts on, every other flow off, and `full_scope_allowed = false`, so its tokens carry no realm roles. Its secret comes from `make secrets`, the same source as the Kubernetes Secret the seeders read.

The upstream realm import stays as it is.

## ADR-032 — One data-tools image, everything through the gateway (accepted 2026-09-18)

Python 3.13 with requests, Faker, confluent-kafka and prometheus-client. One image serves three workloads:
- the `seed-products` Job;
- the `seed-orders` Job;
- the `loadgen` Deployment.

Until Phase 5 CI exists, `make data-tools-image` builds it and pushes it to the k3d registry. The tag is `data-tools/VERSION`, which Terraform reads too.

Every business write goes through APISIX, the same path real clients use:
- products, as the `platform-seeder` service account;
- sign-ups, through the auth-service public route;
- carts, orders and payments, as the signed-up user.

There are two exceptions:
- **The root category.** It is inserted with SQL by an init container, because product-service cannot create a parentless category (upstream finding #11).
- **The `order-context` events.** They go straight to Kafka (ADR-030).

APISIX allows 1200 requests per minute per client address, so each process caps itself at `MAX_RPS` = 15.

Job specs are immutable, so each Job name carries a hash of its inputs. seed-products is idempotent and may retry. seed-orders is not idempotent, so it never retries (`backoffLimit: 0`).

## ADR-033 — The Olist dataset stays out of git and out of images (accepted 2026-09-18)

Olist is licensed CC BY-NC-SA 4.0 and needs a Kaggle login. The operator downloads it into the gitignored `data-tools/data/`.

`make olist-prepare` reduces it to a time-sorted `olist-replay.jsonl.gz`: 5000 orders from 2017-11-01 by default, about 300 KB. The script refuses anything over 900 KiB.

Terraform ships the file as the `olist-replay` ConfigMap. The seed-orders Job exists only if the file does.

The image never contains the data (`.dockerignore`).
