# How this platform was built: order and rationale

This document explains **the order** the platform was built in, and **why** the main technical choices were made. The detailed, dated decision records are in [decisions.md](decisions.md) (ADR-001 … ADR-029). This document is the narrative that connects them.

Status on 2026-09-18:

| Phase | Status |
|---|---|
| 0–3 | Built, deployed and verified on the laptop (minimal profile) |
| 4, 6, 7 | Written and validated offline (see §4), not deployed |
| 5 (CI/CD) | Not started |

---

## 1. The guiding principle

**Build from the bottom of the dependency graph upwards, and prove each layer before stacking the next one.** Each phase has a `make verify-phaseN` script that exercises the real thing and prints PASS/FAIL. A phase counts as done only when its script passes against the live cluster.

The dependency chain drives the order:

```
cluster & nodes ─► namespaces, quotas, network rules ─► operators ─► data stores
      ─► identity + gateway + services (DC1) ─► replication + read side (DC2)
      ─► CI/CD ─► observability ─► chaos
```

Each layer only makes sense once the one below exists. For example:
- NetworkPolicies need namespaces.
- Kafka needs an operator.
- Services need a database and an identity provider.
- A chaos experiment is meaningless without the observability to see its effect.

---

## 2. Build order

### Phase 0 — Scaffolding: repo, tools, Terraform providers

- **What was built:**
  - the repository layout (`terraform/`, `ansible/`, `helm-values/`, `charts/`, `monitoring/`, `docs/`, `scripts/`)
  - the upstream app as a git submodule, pinned to commit `394b34b`
  - an Ansible playbook that installs pinned `terraform`/`kubectl`/`helm`/`k3d`
  - Terraform wired to the k3d kubeconfig
- **Why first:** everything later is code. Tooling and versions have to be reproducible before any infrastructure exists.
- **Key choice: local Terraform state** (ADR-002). A `kubernetes` backend stores state inside the cluster it manages, so recreating the k3d cluster, which is routine, would lose the state.

### Phase 1 — Cluster topology: two simulated datacenters

- **What was built:**
  - a new k3d cluster, `multidc`, with 1 server + 2 agents + a local registry
  - one agent labelled and tainted as DC1, the other as DC2
  - namespaces `dc1-core` and `dc2-analytics`, each with a quota, default container limits and a default-deny NetworkPolicy
- **Why second:** "two datacenters" is the premise of the whole project. The isolation rules must exist before any workload, otherwise workloads are built on assumptions that never get tested.
- **Key choices:**
  - **A new cluster instead of the existing `petclinic` one** (ADR-001). It had a single node, so there was nothing to label as DC1 vs DC2, and no registry for CI.
  - **Pinning by namespace, not per chart** (ADR-008). Two apiserver admission plugins (`PodNodeSelector`, `PodTolerationRestriction`) read namespace annotations and pin *every* pod in a DC namespace to its node. One mechanism covers all charts, with no `nodeSelector` repeated in every values file.
  - **Ingress-only NetworkPolicies with explicit cross-DC allow rules** (ADR-009). Each allowed path between the DCs is one named policy keyed on a pod role label, so the replication contract is readable in one file (`terraform/network-policies.tf`). Restricting egress too would have added DNS/API-server allow rules without blocking any extra path.
- **What the verification caught:** Terraform's node-label and node-taint resources used the same server-side-apply field manager, so the second one silently erased the first. The fix was a separate field manager per resource. The verify script found it; `terraform apply` had reported success.

### Phase 2 — Data stores in DC1, through operators

- **What was built:**
  - cluster-wide operators: Strimzi (Kafka), CloudNativePG (PostgreSQL), cass-operator (Cassandra)
  - a local Helm chart, `charts/datastores`, that renders their custom resources per DC
- **Why before the app:** the services cannot start without their database. Deploying stores first also exposes storage and network problems while there are fewer moving parts.
- **Key choices:**
  - **Operators, not Bitnami charts** (ADR-010). In 2026 Bitnami's free images for Kafka and Cassandra are gone, and the `bitnamilegacy` copies are unpatched. The operators are maintained, and they add what the later phases need: Strimzi also provides Kafka Connect and MirrorMaker 2, and CloudNativePG provides declarative databases and failover.
  - **The custom resources go in a local Helm chart, not `kubernetes_manifest`.** Terraform cannot plan `kubernetes_manifest` resources whose CRDs don't exist yet. A Helm release is only evaluated at apply time, after the operators have installed their CRDs.
  - **Terraform is the only owner of NetworkPolicies** (ADR-012). Strimzi generates its own policy, which opens Kafka to every namespace unless told otherwise. That generation is turned off, so the whole cross-DC contract stays in one place.
  - **Passwords: Ansible generates, Terraform applies** (ADR-011). This keeps the tool boundary clean: Ansible prepares inputs, Terraform owns every Kubernetes object.

### Phase 3 — App layer in DC1: identity, gateway, services

- **What was built:**
  - Keycloak (the upstream realm, with its test users) and APISIX as the gateway, using the upstream routes file
  - the DC1 Spring services, from a generic `charts/spring-service`
  - Debezium change-data-capture on the orders table
  - an end-to-end test: token → cart → order → PostgreSQL row → Kafka event
- **Why this order inside the phase:**
  1. Keycloak first: every service validates JWTs against it at startup.
  2. Then the gateway.
  3. Then the services.
  4. Then the CDC connectors: they need the tables the services create.
- **Key choices:**
  - **APISIX in standalone mode with the upstream routes file** (ADR-013). This reuses the app's own routing instead of re-describing ~80 routes, and avoids running etcd and the ingress controller.
  - **Order events come from Debezium, not from the app** (ADR-014). The upstream order-service has no Kafka producer. The app's own search-service already consumes Debezium-format topics, so CDC is the mechanism the app was designed around.
  - **A fixed token issuer** (`--hostname`), so tokens are valid for services in both DCs whichever URL was used to obtain them.
  - **Config fixes before code fixes.** Missing config values (order-service's schema setting, payment-service's Kafka property) were fixed with environment variables. Real code defects (tax-service's missing `RestClient` bean) were documented and the service disabled, rather than patching the app.
- **What the live run taught:**
  - **The load-balancer IP is the node's own IP.** kube-proxy therefore rewrote the client's source address, and the NetworkPolicy refused it. The fix was `externalTrafficPolicy: Local` on a LoadBalancer Service owned by Terraform, created with its toleration annotation from the start, plus an ipBlock rule for the k3d network.
  - **A new pod's first connection can fail** before kube-router applies NetworkPolicy to it, so the verify script retries the token call.
  - **An order needs a cart:** order-service dereferences `cart.cartId`.
- **A minimal profile** (`terraform/profiles/minimal.tfvars`) was added so the laptop can run the smallest setup that still passes the end-to-end test.

### Phase 4 — DC2: replication and the read side

- **What was written:**
  - DC2 stores: PostgreSQL, a second Kafka, Elasticsearch (ECK), MongoDB, RabbitMQ, RustFS, Mailpit
  - **MirrorMaker 2** replicating selected DC1 topics into DC2
  - Kafka Connect sinks into MongoDB, RabbitMQ and Cassandra
  - the six DC2 services, routed from APISIX in DC1
- **Why after Phase 3:** DC2 is fed by DC1's events. There is nothing to replicate until orders and CDC exist.
- **Key choices:**
  - **MirrorMaker 2 into a second Kafka, running in DC2** (ADR-020). DC2 pulls from DC1, the way a real remote site would. Only one DC2 role (`kafka-replicator`) is allowed into DC1's Kafka. `IdentityReplicationPolicy` keeps topic names unchanged, so DC2 consumers use DC1 names.
  - **DC2 has its own PostgreSQL** (ADR-006), so no database traffic crosses the DC boundary.
  - **Mismatches bridged by configuration** (ADR-021). The product table and key names don't match what search-service expects, so two Kafka Connect transforms bridge them.
  - **Decimals as numbers.** Debezium sends NUMERIC columns as plain numbers (`decimal.handling.mode=double`). By default it sends them as base64 bytes, which the sinks can't read.
  - **RustFS instead of MinIO** (ADR-016). MinIO's repositories were archived in 2025, and the upstream app itself uses RustFS.
  - **Elasticsearch 8.19, not 9.x** (ADR-017), because search-service is built with the Elasticsearch 8 Java client.
  - **cert-manager added** (ADR-015). The RabbitMQ operators need it for their webhooks, which also allowed turning cass-operator's webhooks back on.
- **Known upstream limit:** search-service indexes a product by calling a product-service endpoint that doesn't exist. The pipeline up to that call is built and verifiable; the last step needs an upstream fix (see [upstream-app-findings.md](upstream-app-findings.md) #7).

### Phase 4.5 — Data layer: seed data and live traffic

This phase comes after DC2 and before fraud detection. Detection rules are only as good as the data they are tested on, and the pipelines built in Phases 3 and 4 had only carried single test orders.

- **Written first:** the traffic and its **ground truth**. Every generated order is labelled normal or with its fraud pattern, in a Kafka header that detectors never read. Phase 5a can then be measured, not just observed.
- **Through the front door:** everything goes through APISIX and the real services, even though SQL inserts would be faster. That way seeding also exercises auth, routing, CDC and replication.
- **Gaps closed in the platform layer, not by patching the app:**
  - the missing geography, with the platform-owned `order-context` topic (ADR-030);
  - the missing Keycloak client, with a separate Terraform root (ADR-031);
  - the root category that product-service can't create, with one idempotent SQL insert (upstream finding #11).
- **Tested offline:** the generator's statistics and every input rule the app enforces (password, phone, email) are unit-tested inside the image before any cluster exists.

### Phase 5 — CI/CD (not started)

This belongs between Phase 4 and Phase 6 in the dependency chain. It was skipped because building Phases 6 and 7 was requested first. The recommendation is Jenkins in the cluster with Kubernetes agents, pushing to the k3d registry and upgrading the per-service Helm releases. Its first real job would be building patched images for the two upstream defects.

### Phase 6 — Observability

- **What was written:**
  - Prometheus, Alertmanager and Grafana (kube-prometheus-stack)
  - scrape configurations for every component, and alert rules
  - dashboards: Kafka lag, database connections, per-service latency
  - Fluent Bit → a separate Elasticsearch with Kibana, for logs
  - Icinga, for uptime checks on every data store and Kafka
  - alerts from both Alertmanager and Icinga mailed to Mailpit
- **Why after the workloads:** there must be something to observe. **Why before chaos:** a chaos experiment is only useful if its effect can be measured.
- **Key choices:**
  - **Every scrape configuration and dashboard lives in the repo**, as ServiceMonitor/PodMonitor resources and dashboard JSON files (ADR-023, ADR-024), so a rebuilt cluster has identical monitoring.
  - **Logs in a separate Elasticsearch** (ADR-025), so log volume can never slow down product search.
  - **A local Icinga chart** (ADR-026). The official chart hard-codes `mariadb:latest` and `redis:latest`, and expects checks to be entered through a UI instead of shipped as config.
  - **A monitoring access rule per DC.** Prometheus and Icinga reach the DC pods through one explicit NetworkPolicy per DC, listing exactly the metrics and service ports.

### Phase 7 — Chaos experiments

- **What was written:**
  - Chaos Mesh, allowed to target only the two DC namespaces
  - four experiments: kill the Kafka broker; kill the PostgreSQL primary; cut DC1↔DC2 replication; add WAN latency between the DCs
  - a script that runs one experiment under live order traffic and reports the error window, recovery time and whether every accepted order reached every store downstream
- **Why last:** it tests the whole system. The experiments measure the degradation and recovery that the earlier design choices were meant to provide.
- **Key choices:**
  - **Experiments are not applied by Terraform** (ADR-028). They are one-off, time-boxed events. The demo script applies them and always removes them on exit.
  - **DC1 PostgreSQL runs two instances** (ADR-029), so killing the primary demonstrates a real failover, not just a restart.
  - **Each experiment states a hypothesis**, and the report checks it against data (see [chaos-runbook.md](chaos-runbook.md)).

---

## 3. Cross-cutting choices

- **Terraform owns every Kubernetes object; Ansible only prepares inputs** (ADR-004).
  - **Terraform:** namespaces, policies, Secrets, Helm releases. The whole cluster is described in one place and one state file.
  - **Ansible:** tool installation and password generation, the work that happens outside the cluster.
- **One mechanism per concern, reused.** Examples:
  - pod-to-DC pinning is done once per namespace
  - one policy file holds every cross-namespace path
  - one `datastores` chart renders the stores for DC1, DC2 and monitoring
  - one `spring-service` chart deploys all thirteen services

  Adding a new layer was only chosen when the existing one could not do the job.
- **Pinned versions everywhere.** Charts, operator versions, images (services by digest, since upstream only publishes `latest`) and Kafka Connect plugins (by sha512). A rebuild in six months produces the same system.
- **Feature toggles, not separate stacks.** `enable_kafka`, `enable_cdc`, `enable_cassandra`, `enable_dc2`, `enable_observability`, `enable_chaos`, plus a service list. The same code runs the full platform or the laptop-sized minimal profile.
- **Upstream app left unmodified.** Everything the app needed was supplied by configuration; defects that need code are documented instead of patched. That keeps the platform honest about what the app actually does.

---

## 4. How each piece was verified

| Level | Used for |
|---|---|
| **Live cluster, `make verify-phaseN`** | Phases 1, 2, 3: the real system, end to end |
| **Server-side dry run** against the live API | Phase 3 manifests before applying |
| **Offline, real validators** | Phases 4, 6, 7, with the cluster stopped: Terraform `validate`; every rendered custom resource checked against the real CRD schema of its operator (50 resources, 20 kinds); the real Icinga 2 binary validating the check config; the real `promtool` validating the alert rules |

Offline validation proves the configuration is well-formed and accepted by each tool's own parser. It does not prove runtime behaviour. That is what the `verify-phase4/6/7` scripts are for, once those phases are deployed.

---

## 5. Lessons that shaped the build

1. **Verify every layer against the real thing.** Several faults were invisible until a check ran against the live cluster: the erased taints, the NetworkPolicy refusing load-balancer traffic, the new-pod race, and the order needing a cart. `apply` succeeding is not the same as the system working.
2. **Check that a component is maintained before choosing it.** Bitnami, MinIO and the old MongoDB operator were all abandoned or archived by 2026. Choosing them would have meant unpatched images.
3. **Read the upstream app before designing around it.** Its real behaviour, and not its README, decided several designs:
   - no Kafka producer in order-service
   - Debezium-shaped consumers in search-service
   - schema names that don't match between product-service and search-service
4. **Order operations by their dependencies explicitly.** Several failures came from resources being created in the wrong order:
   - a Secret needed by an operator's finalizer, deleted alongside the resource it protected
   - an annotation that had to exist when a Service was created, not after
   - Helm waiting for an address that could only appear after a later step
