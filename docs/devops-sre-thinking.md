# Thinking like a DevOps / SRE engineer: the "why" behind this project

[build-order-and-rationale.md](build-order-and-rationale.md) says *what* was built, in which order. This document is about the **reasoning habits** behind those decisions: what comes before what and why, and which parts are the platform engineer's job rather than the developer's. Every example comes from this repository.

---

## 1. The questions I ask before touching anything

1. **What already exists, and is it really what the docs say?**
   Before designing, I read the actual source, not the README. In this project the app's code contradicted its documentation several times:
   - order-service has no Kafka producer
   - order-service's schema migration creates no tables
   - product-service lacks an endpoint that search-service calls

   A design built on the docs would have failed at runtime.
2. **What does this depend on, and what depends on it?**
   Everything else follows from the dependency graph. If I can't draw it, I'm not ready to build.
3. **How will I know it works?**
   I decide the check *before* I build. Every phase got a `verify-phaseN` script written alongside the code, not after.
4. **How will I know it's broken, and how fast?**
   This is observability. I think about it at design time even when it's built later.
5. **How do I undo it?**
   If a change can't be reverted or re-created from code, I stop and fix that first.
6. **Is this component maintained?**
   I check before adopting anything. In 2026 Bitnami's free images, MinIO and the old MongoDB operator were abandoned or archived. Picking them would have meant shipping unpatched software.

---

## 2. What comes before what, and why

The order is not arbitrary. Each rule below comes from something that goes wrong when you break it.

### 2.1 Reproducibility before infrastructure

**Pinned tools, a repo layout and the Terraform state location come first (Phase 0).**

*Why:* the first time you create something by hand, you have a snowflake. Every later layer inherits it. It is much cheaper to make "rebuild from scratch" work on day one than to retrofit it.

*Example:* Terraform state is stored locally, not inside the cluster (ADR-002). Here clusters are deleted and recreated routinely, and state stored inside the cluster would die with it. **Decide where the source of truth lives before you create anything it tracks.**

### 2.2 Boundaries before workloads

**Namespaces, quotas and default-deny NetworkPolicies exist before any service (Phase 1).**

*Why:* security and isolation added after the fact always break something. Whatever quietly worked without them becomes "a dependency" nobody declared. With default-deny first, every cross-DC path had to be declared explicitly, and there are exactly the ones in `network-policies.tf`.

*Rule:* **start closed, open deliberately.** Opening one path is a small, reviewable change; closing everything later is a migration.

### 2.3 Prove each layer before stacking the next

Phase N+1 starts only when `verify-phaseN` passes against the live system.

*Why:* bugs compound. The Phase 1 taint bug was an invisible erasure: two Terraform resources overwrote each other while `apply` reported success. Had it been found in Phase 3, it would have looked like "services scheduled on the wrong node" and wasted hours.

*Rule:* **a green `apply` is not a working system.** Verify the behaviour, not the command's exit code.

### 2.4 State before stateless

**Data stores come before the services that use them (Phase 2 before Phase 3).**

*Why:*
- Stateful components are the hardest to change later: storage classes, volumes, backup, failover.
- Services are cheap to redeploy; databases are not.
- Deploying stores first also exposes storage and network problems while there are few moving parts.

### 2.5 Identity before the things that trust it

**Keycloak comes before the services, and the token issuer URL is fixed before any service validates tokens.**

*Why:* every service checks the token issuer at startup. If the issuer URL changes later, every service in both DCs needs reconfiguring. Anything that many components trust, such as identity, DNS names or certificates, must be decided and **stabilised before its consumers exist.**

### 2.6 Producers before consumers, consumers before sinks

**DC1 events → Debezium connectors → MirrorMaker 2 → DC2 sinks.** The connectors are a separate release applied *after* the services, because Debezium needs the tables the services create.

*Rule:* **encode ordering in the tool, not in someone's memory.** Here that's Terraform `depends_on` and separate Helm releases. If the order lives in a README step, it will eventually be run out of order.

### 2.7 Observability before chaos, and ideally before production

**Phase 6 comes before Phase 7.**

*Why:* a chaos experiment without metrics only tells you "something happened". The value is in *measuring* the error window, the recovery time and the lag. More broadly, I prefer observability to exist before real users. Here it came late only because the phases were specified that way. In a real project I would ship basic metrics and logs with Phase 3.

### 2.8 CI/CD before the second environment, not after the tenth manual deploy

Phase 5 is still open. In a real team it would come right after the first service runs, because every manual `helm upgrade` is toil and a source of drift.

*Rule:* **automate the second time you do something, not the tenth.**

### 2.9 The general principle

> Build in the order of *what is most expensive to change later*: state location, network boundaries, identity, data stores. Then the easy-to-redeploy things: services, dashboards, experiments.

---

## 3. What is the platform engineer's responsibility?

This is the question I found most useful to keep asking. A lot of time is lost when a platform engineer "fixes" application code, or a developer is asked about node taints.

### 3.1 Purely DevOps / platform / SRE

| Area | In this project |
|---|---|
| **Infrastructure as code and reproducibility** | Terraform owns every Kubernetes object; Ansible prepares inputs (ADR-004); versions and digests pinned; minimal/full profiles |
| **Environment topology** | Two simulated DCs, pinning pods to nodes, quotas, where each component runs |
| **Network security boundaries** | Default-deny policies, every allowed path named and justified, the external entry path (`externalTrafficPolicy: Local` + ipBlock) |
| **Secrets lifecycle** | Generation (Ansible), storage (Kubernetes Secrets), never in git, rotation path (CloudNativePG `reload` label) |
| **Choosing and operating stateful infrastructure** | Operators for PostgreSQL/Kafka/Cassandra/Elasticsearch/MongoDB/RabbitMQ, storage, replicas, failover (2 PostgreSQL instances) |
| **Delivery pipeline** | Registry, image pinning, how a release reaches each DC (Phase 5) |
| **Observability plumbing** | Prometheus, scrape configs, log shipping, dashboards as code, alert routing |
| **Reliability engineering** | Alerts on symptoms, recovery behaviour, chaos experiments, runbooks |
| **Capacity and cost** | Quotas as the guardrail when nodes overcommit; the minimal profile when the host can't fit everything |
| **Failure-mode knowledge of the platform itself** | Why kube-proxy rewrote the source address, why a new pod's first packet fails, why a finalizer blocked deletion |

### 3.2 Application / development responsibility

| Area | In this project |
|---|---|
| **Business logic and code defects** | tax-service's missing `RestClient` bean; the missing `/storefront/products-es` endpoint; order creation needing a cart |
| **Data model and schema migrations** | order-service's schema migration only runs `SELECT 1`; the table and key naming between product-service and search-service |
| **What the app emits** | Which events exist; which metrics and log fields are meaningful |
| **API contracts between services** | search-service expecting a product endpoint that doesn't exist |

**How I behaved at that boundary:**
- **Config-fixable: I fixed it with configuration and wrote down why.** Examples: the `ddl-auto` override, `KAFKA_BOOTSTRAP_SERVERS`, the Kafka Connect transforms that rename the product topic and key.
- **Code-only: I did not patch the app.** I documented it (`upstream-app-findings.md`), disabled or isolated the component, and made the platform honest about it (verify scripts print "known upstream defect" instead of a fake PASS).
- **Real teams:** these become tickets for the owning team, backed by precise evidence (the stack trace, the file, the commit).

### 3.3 Shared (needs both sides)

| Area | Split |
|---|---|
| **SLOs** | Product/dev decide what "good" means for users; SRE makes it measurable and alertable |
| **Health checks** | The app exposes `/actuator/health`; the platform decides how probes use it and how long startup may take |
| **Instrumentation** | The app emits metrics through Micrometer; the platform enables histograms (via env), scrapes them and builds dashboards |
| **Resilience patterns** | Retries, timeouts and pool sizes live in the app; the platform tests them under failure (Phase 7) and reports the result |
| **Config contracts** | Which env vars the app reads. Several were undocumented and had to be found in the source |

**Rule:** when something breaks, the first question is not "how do I fix it?" but "**whose layer is this in?**" Fix it in the right layer, or hand it to the right owner with evidence.

---

## 4. SRE-specific thinking

### 4.1 Alert on symptoms, investigate with causes

The alert rules in `charts/observability` are mostly **symptoms users would feel**:
- p95 latency high
- 5xx ratio high
- consumer lag growing
- a database with no ready instance

Cause-level signals, like CPU on one pod, belong on dashboards, not in someone's pager.

*Why:* every alert should need a human action. Alerts that fire when nothing is wrong teach people to ignore them.

### 4.2 Two views of availability, on purpose

- **Prometheus** answers: *how well* is it working (rates, latency, lag)?
- **Icinga** answers: *is it reachable at all*, from outside the component, with independent checks?

When one monitoring system is broken, the other still tells you. Redundancy also applies to observability.

### 4.3 Degradation is designed, then proven

Before running each chaos experiment I wrote a **hypothesis**. For example: "killing Kafka does not affect order placement, because order-service writes only to PostgreSQL, and CDC catches up afterwards."

The demo script measures it. A chaos run that only says "it survived" is weak; a run that says "3 requests failed over ~6 s, the primary moved from pg-dc1-1 to pg-dc1-2, and 100 % of accepted orders reached MongoDB" is evidence.

*Rule:* **limit the blast radius first.** Chaos Mesh can only touch annotated namespaces, and every experiment is removed on exit, including on Ctrl-C.

### 4.4 Toil is the enemy; runbooks are the bridge

Anything done by hand twice became a script or a `make` target: `make secrets`, `make tf-apply-minimal`, the `verify-phase*` scripts, the chaos demo.

What can't be automated yet gets a runbook (`chaos-runbook.md`, `observability.md`): exact commands, expected results, and how to abort.

### 4.5 Capacity is a first-class constraint

The laptop could not hold the full stack. The SRE response was not "turn things off until it fits". It was:
- measure what each component actually uses
- put quotas in place as a guardrail, because k3d nodes each report the full host RAM, so the scheduler alone won't stop overcommit
- make the reduced footprint a supported, documented profile

Constraints get designed for, not worked around.

---

## 5. Debugging habits that paid off here

1. **Reproduce at the lowest layer.**
   `localhost:8080` returned `000`. Instead of guessing, I tested each hop:
   - host → node port
   - node → load-balancer pod IP (worked: 401)
   - labelled test pod → APISIX (worked)

   The failing hop was kube-proxy's external rule. Its packet counter matched my requests, which confirmed it.
2. **Change one thing, predict the result, then check.** Before each fix I wrote what the plan should show (for example "2 to add, 0 to destroy") and compared.
3. **Trust the tool, but check the output channel.** Three alert rules looked broken; the real cause was my shell hook truncating long `helm` output. Validating the *untruncated* output showed they were fine. When evidence looks strange, question how it reached you.
4. **Read the operator's own logs and source.** Examples:
   - the stuck Cassandra deletion was explained by one operator log line ("could not load superuser secret")
   - the Strimzi build timeout was a separate setting (`connectBuildTimeoutMs`) found in the operator's config code, not the documented operation timeout
5. **Transient ≠ fixed.** The first token request from a new pod failed; retries worked. I didn't just add a retry. I found the reason (kube-router applies NetworkPolicy to new pods asynchronously) and wrote it next to the retry.

---

## 6. Short version

- **Order by cost of change:** state location, network, identity and data first; services and dashboards later.
- **Start closed, open deliberately,** and write down every opening.
- **Verify behaviour, not exit codes.** Every layer gets its own check before the next one starts.
- **Know whose layer a problem lives in.** Fix platform problems in the platform. Hand application problems to their owners, with evidence.
- **Design failure modes, then prove them** with measured experiments and a limited blast radius.
- **Automate the second repetition, document the rest.**
- **Check that what you adopt is maintained, and read the real code.** Docs describe intent; code describes behaviour.
