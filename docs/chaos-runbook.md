# Chaos runbook (Phase 7)

Chaos Mesh 2.8.4 runs the experiments in `chaos/experiments/`. Only namespaces annotated `chaos-mesh.org/inject=enabled` can be targeted (`controllerManager.enableFilterNamespace`); Terraform annotates `dc1-core` and `dc2-analytics` when `enable_chaos = true`.

`scripts/chaos-demo.sh <scenario>` (or `make chaos-*`) does the whole demo:
1. It starts order traffic through APISIX in DC1: token, then cart, then order, every 2 s, each order tagged with the run id.
2. It records a baseline, injects the fault, and waits for recovery.
3. It removes the experiment and prints a report:
   - success rate before, during and after the fault
   - the longest error window
   - the PostgreSQL primary before and after
   - peak Kafka lag and MirrorMaker 2 latency
   - whether every accepted order reached DC1 PostgreSQL, the CDC topic, and DC2 MongoDB

`BASELINE` and `OBSERVE` (in seconds) tune the windows. The script deletes the experiment on exit, including on Ctrl-C.

Readiness: `make verify-phase7` checks that chaos-daemon runs on every node (including the tainted DC nodes), that the namespaces are opted in, and that every experiment is accepted by a server-side dry run.

## Scenarios

### 1. `kafka-broker-kill` — DC1 Kafka broker dies (`make chaos-kafka`)

**Hypothesis.**
- Order placement is unaffected, because order-service writes to PostgreSQL only.
- Debezium (connect-dc1) and MirrorMaker 2 lose their broker and retry.
- Strimzi recreates the broker with the same PVC. Once it is back, CDC resumes from the replication slot and MirrorMaker 2 catches up.
- No accepted order goes missing downstream.

**Expect:**
- "during" success stays at about 100 %
- recovery takes one broker restart
- the report's PostgreSQL, topic and MongoDB counts all match

**Watch:**
- *Strimzi Kafka* (broker gone and back)
- *Strimzi Kafka Connect* (task restarts)
- *Platform: services, databases, Kafka*, where "Kafka consumer-group lag" spikes and drains
- Alertmanager and Icinga mail in Mailpit: `KafkaBrokerNotReady` and `dc1-kafka DOWN`, then RECOVERY

### 2. `postgres-primary-kill` — DC1 PostgreSQL primary dies (`make chaos-postgres`)

**Hypothesis.**
- With `dc1_pg_instances = 2`, CloudNativePG promotes the streaming replica and moves `pg-dc1-rw`.
- Order writes fail only during the switchover.
- The Hikari pools in order-service reconnect.
- Debezium resumes from its logical replication slot, which CloudNativePG synchronises to the replica.

**Expect:**
- a short error window of a few requests
- the primary changes (for example `pg-dc1-1 → pg-dc1-2`)
- traffic back to 100 % afterwards
- downstream counts match the accepted orders

**Watch:**
- *CloudNativePG* (primary switch, replication lag)
- *Platform* (5xx rate, Hikari pending connections)
- Icinga `dc1-postgresql` flapping

### 3. `dc-partition` — DC1 and DC2 lose each other for 3 minutes (`make chaos-partition`)

**Hypothesis.**
- The only data path between the DCs is MirrorMaker 2 (DC2) reading Kafka (DC1).
- With that path cut, DC1 keeps taking orders.
- DC2 keeps serving reads from its own stores, which become stale.
- MirrorMaker 2 lag grows, then drains after the partition heals.

**Expect:**
- DC1 success stays at about 100 %
- MongoDB catches up to the PostgreSQL count after healing (the script waits up to 3 minutes)

**Watch:**
- *Strimzi Kafka Mirror Maker 2* (record age, latency)
- *Platform*: "MirrorMaker 2 replication latency"

### 4. `cross-dc-latency` — WAN latency between the DCs for 5 minutes (`make chaos-latency`)

**Hypothesis.** 250 ms ± 50 ms of delay on the replication path raises MirrorMaker 2 latency. There are no errors and no data loss.

**Expect:** a higher "peak MirrorMaker 2 latency" in the report, and all counts matching.

## Abort and cleanup

```bash
kubectl delete -f chaos/experiments/<scenario>.yaml    # stops the fault immediately
kubectl -n dc1-core delete pod -l chaos-run            # traffic pods of any run
```

Pod-kill experiments are one-shot. Network experiments end at `duration` or when deleted.

## Limits

- **Single node per DC.** A k3d node is one container, so "DC loss" is simulated by partitioning the replication path, not by stopping a node. Stopping a node container would also take down its PVCs, which live on that node's local-path storage.
- **Single-broker Kafka.** Replication factor 1, as specified in Phase 2. The broker kill is therefore a full Kafka outage for DC1, not a leader election.
- **One service call is broken upstream.** search-service indexing depends on a product-service endpoint that does not exist (`docs/upstream-app-findings.md` #7). Scenarios therefore measure orders, not search.
