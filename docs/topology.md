# Cluster topology and workload pinning (Phase 1)

## Nodes

| Node                  | Role                | Labels                                                     | Taint                           |
|-----------------------|---------------------|------------------------------------------------------------|---------------------------------|
| `k3d-multidc-server-0`| control plane, add-ons | —                                                       | none                            |
| `k3d-multidc-agent-0` | DC1                 | `topology.kubernetes.io/zone=dc1`, `platform.local/dc=dc1` | `platform.local/dc=dc1:NoSchedule` |
| `k3d-multidc-agent-1` | DC2                 | `topology.kubernetes.io/zone=dc2`, `platform.local/dc=dc2` | `platform.local/dc=dc2:NoSchedule` |

Labels and taints are owned by Terraform (`terraform/topology.tf`), not by the k3d config.

Both resources patch the same Node object through server-side apply. Each needs its own `field_manager` (`terraform-dc-labels` and `terraform-dc-taints`). With the shared default manager, the labels apply removed the taints on the first apply.

## Affinity rules: how pods get pinned

Pinning is enforced per **namespace** by two apiserver admission plugins. `k3d/multidc-cluster.yaml` enables them with `--kube-apiserver-arg=enable-admission-plugins=...`. No chart needs `nodeSelector` or `tolerations`.

| Namespace       | `scheduler.alpha.kubernetes.io/node-selector` | `scheduler.alpha.kubernetes.io/defaultTolerations` |
|-----------------|-----------------------------------------------|----------------------------------------------------|
| `dc1-core`      | `topology.kubernetes.io/zone=dc1`             | tolerate `platform.local/dc=dc1:NoSchedule`        |
| `dc2-analytics` | `topology.kubernetes.io/zone=dc2`             | tolerate `platform.local/dc=dc2:NoSchedule`        |

- **PodNodeSelector** merges the namespace selector into every pod. A pod whose own `nodeSelector` conflicts is **rejected** at admission.
- **PodTolerationRestriction** adds the default toleration to every pod.
- **The taint is the other half.** Pods from any other namespace, such as future monitoring or CI, cannot land on a DC node unless they tolerate it. DaemonSets that must run on every node, like Fluent Bit in Phase 6, need `tolerations: [{key: platform.local/dc, operator: Exists}]`.

Fallback if the plugins turn out not to be active: set `nodeSelector` and `tolerations` in each chart's values under `helm-values/<dc>/`.

## NetworkPolicy contract

Every DC namespace has `default-deny-ingress` and `allow-same-namespace`. Cross-DC traffic is allowed only for pods carrying `platform.local/role`:

| Policy (namespace)                                  | Destination role | Source (namespace / role)          | Ports |
|-----------------------------------------------------|------------------|------------------------------------|-------|
| `allow-dc2-replicator-to-kafka` (dc1-core)          | `kafka-broker`   | dc2-analytics / `kafka-replicator` | 9092  |
| `allow-dc2-services-to-keycloak` (dc1-core)         | `keycloak`       | dc2-analytics / `api-service`      | 8080  |
| `allow-dc1-gateway-to-services` (dc2-analytics)     | `api-service`    | dc1-core / `api-gateway`           | 8081, 8083, 8089, 8090, 8093, 8094 |
| `allow-operators-to-kafka` (dc1-core)               | `kafka-broker`   | platform-operators / any pod       | 9090, 9091, 8443 |
| `allow-operators-to-postgres` (dc1-core)            | `postgres`       | platform-operators / any pod       | 8000, 5432 |
| `allow-operators-to-cassandra` (dc1-core)           | `cassandra`      | platform-operators / any pod       | 8080  |
| `allow-operators-to-kafka-connect` (dc1-core)       | `kafka-connect`  | platform-operators / any pod       | 8083  |
| `allow-external-to-gateway` (dc1-core)              | `api-gateway`    | ipBlock `var.external_client_cidr` (k3d network, default 172.25.0.0/16) | 9080 |
| `allow-dc2-search-to-product` (dc1-core)            | `app.kubernetes.io/name=product-service` | dc2-analytics / `app.kubernetes.io/name=search-service` | 8086 |
| `allow-operators-to-kafka` (dc2-analytics)          | `kafka-broker`   | platform-operators / any pod       | 9090, 9091, 8443 |
| `allow-operators-to-kafka-connect` (dc2-analytics)  | `kafka-connect`  | platform-operators / any pod       | 8083  |
| `allow-operators-to-mirrormaker2` (dc2-analytics)   | `kafka-replicator` | platform-operators / any pod     | 8083  |
| `allow-operators-to-postgres` (dc2-analytics)       | `postgres`       | platform-operators / any pod       | 8000, 5432 |
| `allow-operators-to-elasticsearch` (dc2-analytics)  | `elasticsearch`  | platform-operators / any pod       | 9200  |
| `allow-operators-to-mongodb` (dc2-analytics)        | `mongodb`        | platform-operators / any pod       | 27017 |
| `allow-topology-operator-to-rabbitmq` (dc2-analytics) | `rabbitmq`     | rabbitmq-system / any pod          | 15672 |
| `allow-monitoring` (dc1-core)                       | any pod          | monitoring / any pod (Prometheus, Icinga) | 9000, 9404, 9187, 9091, 8080, 5432, 9092, 9042, 9080, 8083 |
| `allow-monitoring` (dc2-analytics)                  | any pod          | monitoring / any pod (Prometheus, Icinga, Alertmanager) | 9000, 9404, 9187, 15692, 9108, 9216, 8080, 5432, 9092, 9200, 27017, 5672, 8083, 25 |

Roles:
- `charts/datastores` sets `postgres` (CNPG `inheritedMetadata`), `kafka-broker` (KafkaNodePool `template.pod`), `kafka-connect` (KafkaConnect `template.pod`) and `cassandra` (CassandraDatacenter `additionalLabels`).
- `charts/spring-service` sets `api-service`.
- The Keycloak values set `keycloak` (`podLabels`). The APISIX values set `api-gateway` (`service.labelsOverride`).
- `charts/data-tools` (Phase 4.5) sets `data-seeder` (seed Jobs) and `load-generator` (loadgen). They live in dc1-core and only call APISIX, Keycloak, pg-dc1 (root category) and kafka-dc1 there, so they need no cross-namespace path. Their only outbound internet call is DummyJSON, and egress is open.

### External traffic path

`http://localhost:8080` → k3d load balancer (nginx, `172.25.0.5`) → port 80 on the DC1 node → kube-proxy → APISIX pod.

- **Node IP as LoadBalancer IP.** k3s servicelb publishes node IPs as the LoadBalancer IPs, so kube-proxy handles this traffic, not the servicelb pod.
- **Why `externalTrafficPolicy: Local`.** Under `Cluster`, kube-proxy SNATs the traffic to a node address, which the NetworkPolicy then refuses. `Local` keeps the k3d-network source address. It also means k3s publishes only nodes with a ready APISIX endpoint (the DC1 node), so the DC1 node is the only one that accepts external traffic.
- **Toleration annotation.** The servicelb pods need the Service annotation `svccontroller.k3s.cattle.io/tolerations` to run on the tainted DC1 node. The annotation must be present when the Service is created, so Terraform owns this Service (`apisix-external`); the chart's own `apisix-gateway` Service is ClusterIP. The first attempt added the annotation after a chart-owned LoadBalancer Service, and Helm hung waiting for an address that `Local` never published.

The `platform-operators` namespace has no pinning annotations, quota or default-deny, so its pods run on the untainted server node.

Enforcement is ingress-only. Egress stays open so DNS, the API server and image-related traffic need no allow rules. A pod can still *attempt* a cross-DC connection, but the receiving namespace drops it.

## Sizing

The host has 4 CPUs and 15 GiB RAM. Each namespace quota is `requests.memory=6Gi`, `limits.memory=9Gi`, 30 pods and 40 Gi of PVCs. k3d nodes are containers sharing the same host memory: each agent reports the full host RAM as allocatable, so the scheduler will not stop overcommit. **The quotas are the guardrail.** The upstream manifests request 512 Mi per Spring Boot service. Phase 3 and 4 values will lower that where possible.

## Verify

```bash
make verify-phase1
kubectl get ns dc1-core dc2-analytics -o yaml | grep scheduler.alpha
kubectl -n dc1-core get resourcequota,limitrange,networkpolicy
kubectl -n dc2-analytics get resourcequota,limitrange,networkpolicy
```
