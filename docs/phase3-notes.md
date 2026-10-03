# Phase 3 notes: what runs, how to reach it, how to run it smaller

Snapshot from 2026-09-15, around 14:30–15:15 CEST. The terminal outputs at the end are the evidence for each statement.

## 1. Status of the DC1 app layer

| Component | State | Evidence (terminal section) |
|---|---|---|
| Keycloak | Running; issues tokens for `testuser` with issuer `http://keycloak.dc1-core.svc.cluster.local:8080/realms/ecommerce` and role `USER` | T4 |
| APISIX (in-cluster `apisix-gateway`) | Running. Routes traffic; rejects protected routes without a token (401) | T4, T5 |
| product-service | Works: `GET /api/products` and `GET /api/categories` return 200 (empty lists) | T4, T5 |
| order-service | Works: `POST /api/carts`, then `POST /api/orders` with that `cartId` returns 200, and the row is in `orderservice.orders` | T5 |
| inventory-service | Works: `GET /api/inventory?productName=iphone` returns 200 `[]` | T5 |
| auth-service | Responds. `GET /api/v1/users?username=testuser` returns 404 "user not found", because Keycloak users are not copied into auth-service's own database | T5 |
| shipping-service | Responds, but `GET /shipping/api/shippings/1/1` returns 500 with no shipping data. Not investigated | T5 |
| payment-service | CrashLoopBackOff: missing property `kafka.bootstrap.servers`. Fix written, not applied | T1 |
| tax-service | CrashLoopBackOff: upstream code defect (no `RestClient` bean). Disabled in code, not applied | T1 |
| Kafka Connect (Debezium) | Image build still running; very CPU-heavy (`buildah` at 92% in `top`) | top output, T3 |
| `http://localhost:8080` | Not working yet: `apisix-gateway` LoadBalancer stays `<pending>`. Fix written, not applied | pasted `kubectl get svc` |

Why an order needs a cart: `OrderServiceImpl` reads `orderDto.getCartDto().getCartId()`. An order posted without `"cart"` fails with `NullPointerException` and HTTP 500 (T4).

## 2. What each Docker container is

| Container | Role |
|---|---|
| `k3d-multidc-serverlb` | **Nginx proxy in front of the cluster.** Host `8080` goes to port 80 on the nodes (app traffic, the future `localhost:8080` gateway). Host `34707` goes to the Kubernetes API on `server-0:6443`; this is what `kubectl` talks to, via `~/.kube/config`. |
| `k3d-multidc-server-0` | **Control plane.** Kubernetes API, scheduler, controllers and datastore. Also runs the cluster add-ons (CoreDNS, local-path storage, metrics-server) and the three operators in `platform-operators` (Strimzi, CloudNativePG, cass-operator). Uses about 1.2 GiB. |
| `k3d-multidc-agent-0` | **Simulated DC1 node.** Runs every `dc1-core` pod: PostgreSQL, Kafka, Cassandra, Keycloak, APISIX and the services. Uses about 4.5 GiB and is where the memory goes. |
| `k3d-multidc-agent-1` | **Simulated DC2 node.** Empty until Phase 4 (about 80 MiB). |
| `registry.localhost` | **Local image registry** on port 5000. The Kafka Connect build pushes here, and Phase 5 CI will too. |
| `postgres` (5 weeks old) | **Not part of this project.** Your own PostgreSQL container on host port 5432. |

## 3. Browser access (works today, no apply needed)

`kubectl port-forward` tunnels one Service to your machine. It bypasses the k3d load balancer and the NetworkPolicies.

```bash
# Public API routes through the gateway
kubectl -n dc1-core port-forward svc/apisix-gateway 9080:80
#   http://localhost:9080/api/products
#   http://localhost:9080/api/categories

# Swagger UI of one service (repeat with another port for other services)
kubectl -n dc1-core port-forward svc/product-service 8086:8086
#   http://localhost:8086/product/swagger-ui/index.html      (verified 200)
kubectl -n dc1-core port-forward svc/order-service 8084:8084
#   http://localhost:8084/order/swagger-ui/index.html        (same pattern, not tested)
```

A browser cannot add a `Bearer` token, so call protected routes (orders, carts, inventory, users) with curl:

```bash
kubectl -n dc1-core port-forward svc/keycloak 18080:8080 &
kubectl -n dc1-core port-forward svc/apisix-gateway 9080:80 &
TOKEN=$(curl -s -d grant_type=password -d client_id=ecommerce-client \
  -d username=testuser -d password=testpass \
  http://localhost:18080/realms/ecommerce/protocol/openid-connect/token \
  | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')
curl -s -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"userId":1}' http://localhost:9080/api/carts
curl -s -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"orderDesc":"from-my-laptop","orderFee":10,"productId":1,"cart":{"cartId":1}}' \
  http://localhost:9080/api/orders
curl -s -H "Authorization: Bearer $TOKEN" http://localhost:9080/api/orders
```

**Keycloak admin console: not reachable from a browser yet.** `/admin/` redirects to `http://keycloak.dc1-core.svc.cluster.local:8080/admin/master/console/`, the in-cluster name pinned by `--hostname` (T4). Keycloak 26 has `--hostname-admin=<url>`, which moves only the admin console to another URL while tokens keep the in-cluster issuer. Adding `--hostname-admin=http://localhost:18080` to `helm-values/dc1-core/keycloak.yaml` would make the console work through the port-forward above. That is proposed, not applied. The admin password is in `ansible/.secrets/dc1_keycloak_admin`.

## 4. Running it with fewer resources

`top` showed a load average of about 10 on 4 CPUs, 964 MiB free and 2.3 GiB of swap in use. Measured consumers (T3):

| Consumer | Memory | CPU note |
|---|---|---|
| Cassandra (`ecommerce-dc1-r1-sts-0`) | ~1 GiB | not used by anything yet |
| Kafka broker | ~660 MiB | needed |
| Keycloak | ~510 MiB | needed for tokens |
| 5 Spring services | ~290 MiB each (~1.5 GiB) | |
| Strimzi operator | ~260 MiB | |
| Kafka Connect build (`buildah`) | ~100–290 MiB | **~90% CPU** while building |
| Outside this project: `zammad` Ruby processes, several `java` processes, pgAdmin, Teams, VS Code | several GiB | Ruby at 56–70% CPU in `top` |

Options, cheapest first:

1. **Stop the cluster when you're not using it.** Nothing is lost: volumes and Terraform state stay.
   ```bash
   k3d cluster stop multidc     # frees ~6 GiB and all cluster CPU
   k3d cluster start multidc
   ```
2. **Turn off what Phase 3 doesn't need.** In `terraform/terraform.tfvars`:
   ```hcl
   enable_cassandra = false   # ~1 GiB; only needed for the later Kafka->Cassandra sink
   enable_cdc       = false   # stops the buildah build (CPU) and Kafka Connect (~800 MiB); needed for order events and Phase 4 search
   ```
3. **Keep only the services you're learning with.** In `helm-values/dc1-core/services.yaml`, set `enabled: false` on `shipping-service`, `inventory-service` and `auth-service` (~290 MiB each). The token/cart/order flow only needs Keycloak, APISIX, product-service and order-service.
4. **Outside the cluster.** The biggest non-project consumers in `top` are the `zammad` Ruby workers and the other `java` processes. Stopping them, if you don't need them while studying, frees more than any single cluster change.

With steps 2 and 3, DC1 drops from ~4.5 GiB to about 2.3 GiB: PostgreSQL, Kafka, Keycloak, APISIX and two services.

## 5. Written but not applied yet

These are in the repo; the next `make tf-apply` picks them up.

- **payment-service:** `KAFKA_BOOTSTRAP_SERVERS` env var (`helm-values/dc1-core/services.yaml`).
- **tax-service:** `enabled: false`, upstream defect (`docs/upstream-app-findings.md`).
- **`localhost:8080`:** the chart's `apisix-gateway` becomes ClusterIP. A Terraform-owned `apisix-external` LoadBalancer Service is created with `externalTrafficPolicy: Local` and the toleration annotation from the start (`terraform/gateway-identity-dc1.tf`).
- **Kafka Connect:** `connectBuildTimeoutMs: 1800000` for the Strimzi build (`helm-values/platform-operators/strimzi.yaml`).
- **`scripts/verify-phase3.sh`:** now creates a cart before the order.

The releases that failed are not in Terraform state, so remove them before applying:

```bash
helm --kube-context k3d-multidc -n dc1-core uninstall apisix payment-service tax-service
make tf-apply
make verify-phase3
```

---

## Terminal

### T1 — pods and quota (pasted by you)

```text
$ K="kubectl --context k3d-multidc -n dc1-core"; $K get pods -o custom-columns='NAME:.metadata.name,PHASE:.status.phase,READY:.status.containerStatuses[*].ready,RESTARTS:.status.containerStatuses[*].restartCount,LAST:.status.containerStatuses[*].lastState.terminated.reason,NODE:.spec.nodeName' 2>&1; echo ---quota; $K get resourcequota dc1-quota -o jsonpath='{.status.used}{"\n"}'
NAME                                         PHASE     READY       RESTARTS   LAST     NODE
apisix-975c7b74d-n88pg                       Running   true        0          <none>   k3d-multidc-agent-0
auth-service-7f677cf954-sh9hw                Running   true        0          <none>   k3d-multidc-agent-0
connect-dc1-connect-build                    Running   true        0          <none>   k3d-multidc-agent-0
e2e-order                                    Running   true        0          <none>   k3d-multidc-agent-0
ecommerce-dc1-r1-sts-0                       Running   true,true   0,0        <none>   k3d-multidc-agent-0
inventory-service-7598dc6458-ggjw5           Running   true        0          <none>   k3d-multidc-agent-0
kafka-dc1-dual-role-0                        Running   true        0          <none>   k3d-multidc-agent-0
kafka-dc1-entity-operator-56bd5d77f8-5w8wz   Running   true        0          <none>   k3d-multidc-agent-0
keycloak-0                                   Running   true        0          <none>   k3d-multidc-agent-0
order-service-77d4c47798-8zt8n               Running   true        0          <none>   k3d-multidc-agent-0
payment-service-84f99db79b-km27c             Running   false       6          Error    k3d-multidc-agent-0
pg-dc1-1                                     Running   true        0          <none>   k3d-multidc-agent-0
product-service-6958fcc4bd-xkm7z             Running   true        0          <none>   k3d-multidc-agent-0
shipping-service-848759d9f5-w7kfx            Running   true        0          <none>   k3d-multidc-agent-0
tax-service-65557b6754-mxgml                 Running   false       6          Error    k3d-multidc-agent-0
---quota
{"limits.cpu":"14600m","limits.memory":"10Gi","persistentvolumeclaims":"3","pods":"15","requests.cpu":"1420m","requests.memory":"6464Mi","requests.storage":"12Gi"}

$ kubectl -n dc1-core get pods -o wide
NAME                                         READY   STATUS             RESTARTS        AGE    IP           NODE                  NOMINATED NODE   READINESS GATES
apisix-975c7b74d-n88pg                       1/1     Running            0               24m    10.42.2.20   k3d-multidc-agent-0   <none>           <none>
auth-service-7f677cf954-sh9hw                1/1     Running            0               19m    10.42.2.26   k3d-multidc-agent-0   <none>           <none>
connect-dc1-connect-build                    1/1     Running            0               11m    10.42.2.29   k3d-multidc-agent-0   <none>           <none>
e2e-order                                    0/1     Completed          0               40s    10.42.2.30   k3d-multidc-agent-0   <none>           <none>
ecommerce-dc1-r1-sts-0                       2/2     Running            0               161m   10.42.2.9    k3d-multidc-agent-0   <none>           <none>
inventory-service-7598dc6458-ggjw5           1/1     Running            0               19m    10.42.2.23   k3d-multidc-agent-0   <none>           <none>
kafka-dc1-dual-role-0                        1/1     Running            0               160m   10.42.2.10   k3d-multidc-agent-0   <none>           <none>
kafka-dc1-entity-operator-56bd5d77f8-5w8wz   1/1     Running            0               157m   10.42.2.11   k3d-multidc-agent-0   <none>           <none>
keycloak-0                                   1/1     Running            0               23m    10.42.2.21   k3d-multidc-agent-0   <none>           <none>
order-service-77d4c47798-8zt8n               1/1     Running            0               19m    10.42.2.28   k3d-multidc-agent-0   <none>           <none>
payment-service-84f99db79b-km27c             0/1     CrashLoopBackOff   6 (4m49s ago)   19m    10.42.2.24   k3d-multidc-agent-0   <none>           <none>
pg-dc1-1                                     1/1     Running            0               153m   10.42.2.12   k3d-multidc-agent-0   <none>           <none>
product-service-6958fcc4bd-xkm7z             1/1     Running            0               19m    10.42.2.27   k3d-multidc-agent-0   <none>           <none>
shipping-service-848759d9f5-w7kfx            1/1     Running            0               19m    10.42.2.25   k3d-multidc-agent-0   <none>           <none>
tax-service-65557b6754-mxgml                 0/1     CrashLoopBackOff   6 (4m12s ago)   19m    10.42.2.22   k3d-multidc-agent-0   <none>           <none>

$ kubectl -n kube-system get pods -l svccontroller.k3s.cattle.io/svcname=apisix-gateway -o wide
NAME                                  READY   STATUS    RESTARTS   AGE   IP           NODE                   NOMINATED NODE   READINESS GATES
svclb-apisix-gateway-c28642ed-rcr2h   1/1     Running   0          24m   10.42.0.11   k3d-multidc-server-0   <none>           <none>

$ kubectl -n dc1-core get svc apisix-gateway
NAME             TYPE           CLUSTER-IP      EXTERNAL-IP   PORT(S)        AGE
apisix-gateway   LoadBalancer   10.43.239.175   <pending>     80:30303/TCP   24m
```

### T2 — Docker containers (pasted by you)

```text
$ docker ps
CONTAINER ID   IMAGE                            COMMAND                  CREATED       STATUS       PORTS                                                              NAMES
d369e0029974   ghcr.io/k3d-io/k3d-proxy:5.9.0   "/bin/sh -c nginx-pr…"   3 hours ago   Up 3 hours   0.0.0.0:8080->80/tcp, [::]:8080->80/tcp, 0.0.0.0:34707->6443/tcp   k3d-multidc-serverlb
76b5dc46042b   rancher/k3s:v1.35.5-k3s1         "/bin/k3d-entrypoint…"   3 hours ago   Up 3 hours                                                                      k3d-multidc-agent-1
769df4ee887d   rancher/k3s:v1.35.5-k3s1         "/bin/k3d-entrypoint…"   3 hours ago   Up 3 hours                                                                      k3d-multidc-agent-0
f4de58a50f4c   rancher/k3s:v1.35.5-k3s1         "/bin/k3d-entrypoint…"   3 hours ago   Up 3 hours                                                                      k3d-multidc-server-0
9a700d016e88   registry:2                       "/entrypoint.sh /etc…"   3 hours ago   Up 3 hours   0.0.0.0:5000->5000/tcp                                             registry.localhost
c52b264c509d   postgres:16                      "docker-entrypoint.s…"   5 weeks ago   Up 5 hours   0.0.0.0:5432->5432/tcp, [::]:5432->5432/tcp                        postgres
```

### T3 — resource usage (collected 2026-09-15 ~15:00)

```text
$ free -m
               total       utilisé      libre     partagé tamp/cache   disponible
Mem:           15930       10414         434         157        5462        5516

$ docker stats --no-stream --format '{{.Name}} cpu={{.CPUPerc}} mem={{.MemUsage}}'
k3d-multidc-serverlb cpu=0.00% mem=4.016MiB / 15.56GiB
k3d-multidc-agent-1 cpu=1.01% mem=81.11MiB / 15.56GiB
k3d-multidc-agent-0 cpu=10.58% mem=4.55GiB / 15.56GiB
k3d-multidc-server-0 cpu=8.78% mem=1.207GiB / 15.56GiB
registry.localhost cpu=0.01% mem=12.34MiB / 15.56GiB
postgres cpu=0.00% mem=19.01MiB / 15.56GiB

$ kubectl top pods -A   (sorted by memory)
dc1-core             ecommerce-dc1-r1-sts-0                       15m   994Mi
dc1-core             kafka-dc1-dual-role-0                        21m   663Mi
dc1-core             keycloak-0                                   2m    512Mi
dc1-core             order-service-77d4c47798-8zt8n               2m    300Mi
dc1-core             product-service-6958fcc4bd-xkm7z             3m    299Mi
dc1-core             inventory-service-7598dc6458-ggjw5           2m    295Mi
dc1-core             auth-service-7f677cf954-sh9hw                2m    293Mi
dc1-core             shipping-service-848759d9f5-w7kfx            4m    284Mi
platform-operators   strimzi-cluster-operator-5dbd99cfd-5tv4f     42m   258Mi
dc1-core             pg-dc1-1                                     7m    220Mi
dc1-core             kafka-dc1-entity-operator-56bd5d77f8-5w8wz   2m    161Mi
dc1-core             apisix-975c7b74d-n88pg                       3m    109Mi
dc1-core             connect-dc1-connect-build                    23m   105Mi
platform-operators   cnpg-cloudnative-pg-8cf4dcc6-gwsss           2m    27Mi
kube-system          metrics-server-786d997795-q6g6k              4m    26Mi
platform-operators   cass-operator-544dcc47cd-mqq27               1m    22Mi
kube-system          coredns-8db54c48d-cl5hq                      2m    15Mi
kube-system          local-path-provisioner-5d9d9885bc-2qx4q      1m    9Mi
```

### T4 — gateway, Swagger and Keycloak through port-forward (order without cart)

```text
token length: 1139
iss: http://keycloak.dc1-core.svc.cluster.local:8080/realms/ecommerce roles: ['USER']
== via APISIX (port-forward svc/apisix-gateway 19080:80)
GET    /api/products                            no-token=200  token=200
GET    /api/categories                          no-token=200  token=200
GET    /api/orders                              no-token=401  token=200
GET    /api/carts                               no-token=401  token=200
GET    /api/inventory                           no-token=401  token=400
GET    /shipping/api/shippings/                 no-token=401  token=404
GET    /api/v1/users                            no-token=401  token=400
POST   /api/orders                              token=500 body={"success":false,"code":"ERR-0500","message":"An unexpected error occurred. Please try again later.","path":"/order/api/orders","traceId":"504ae730-d35f-4449-b2
order row: 0
== swagger (port-forward svc/product-service 18086:8086)
/product/swagger-ui.html            401 ->
/product/swagger-ui/index.html      200 ->
/product/v3/api-docs                200 ->
== keycloak admin via port-forward
GET /admin/ -> 302 Location=http://keycloak.dc1-core.svc.cluster.local:8080/admin/master/console/
GET /admin/master/console/ -> 200
"authUrl": "http://keycloak.dc1-core.svc.cluster.local:8080"

$ kubectl -n dc1-core logs deploy/order-service --since=10m | grep -iE 'ERROR|Exception'
ERROR ... ApiExceptionHandler : ApiError uri=/order/api/orders status=500 code=ERR-0500 ...
java.lang.NullPointerException: Cannot invoke "com.ecommerce.orderservice.dto.order.CartDto.getCartId()" because the return value of "com.ecommerce.orderservice.dto.order.OrderDto.getCartDto()" is null
ERROR ... HttpLoggingFilter : order/api/orders | POST | 500 | 21ms | ... | req={"orderDesc":"notes-1789477918","orderFee":42.5,"productId":1}
```

### T5 — cart, then order, then PostgreSQL (the working flow)

```text
== 1. create cart
{"cartId":1,"userId":1}
cartId=1
== 2. create order in that cart
HTTP 200
{"orderId":1,"orderDate":null,"orderDesc":"notes-1789477996","orderFee":42.5,"productId":1,"cart":{"cartId":1,"userId":null}}

== 3. row in PostgreSQL
 order_id |    order_desc    | order_fee | cart_id
----------+------------------+-----------+---------
        1 | notes-1789477996 |      42.5 |       1
(1 row)

== 4. other services with required parameters
GET /api/inventory?productName=iphone             200  []
GET /api/v1/users?username=testuser               404  {"success":false,"code":"ERR-0404","message":"Không tìm thấy người dùng với username testuser.","pat
GET /shipping/api/shippings/find                  400  {"success":false,"code":"ERR-0400","message":"The request is invalid.","path":"/shipping/api/shippings/find","
GET /shipping/api/shippings/1/1                   500  {"success":false,"code":"ERR-0500","message":"An unexpected error occurred. Please try again later.","path":"/
GET /api/products                                 200  []
```


---

## 2026-09-18 — minimal test profile

`make tf-apply-minimal` applies `terraform/profiles/minimal.tfvars`:

- **Running:** operators, PostgreSQL, Keycloak, APISIX, product-service, order-service.
- **Off:** Kafka (`enable_kafka`), Kafka Connect/Debezium (`enable_cdc`), Cassandra (`enable_cassandra`), and auth/payment/inventory/shipping/tax (`dc1_services`).
- order-service has no Kafka producer or listener, and common-kafka is an optional dependency, so it starts without a broker.
- Data volumes (PVCs) of disabled stores are kept, so re-enabling reuses them.

**Result:** `make verify-phase3` passed every check.

- Workloads ready, pinned to the DC1 node.
- **`http://localhost:8080` works:** it returns 401 without a token.
- The end-to-end flow passed: token, then `POST /api/carts`, then `POST /api/orders` (200), then the row in `orderservice.orders`.
- The DC1 node uses 1.8 GiB, down from 4.55 GiB.

**Fixed along the way:**

1. **APISIX chart:** it always renders `externalTrafficPolicy` (default `Cluster`), which the API rejects on a ClusterIP Service. The fix sets `service.externalTrafficPolicy: ""` in `helm-values/dc1-core/apisix.yaml`.
2. **Cassandra teardown:** turning Cassandra off also deleted its superuser Secret, so cass-operator could not run the CR finalizer. The CR stayed in deletion with "could not load superuser secret". The Secret is now unconditional. Once it was back, a reconcile removed the CR.
3. **New-pod NetworkPolicy race:** a new pod's first connection can fail (HTTP 000) until kube-router programs NetworkPolicy for it. `verify-phase3.sh` now retries the token request (`--retry 5 --retry-all-errors`).

### T6 — minimal profile snapshot

```text
$ kubectl -n dc1-core get pods
NAME                               READY   STATUS    RESTARTS        AGE
apisix-975c7b74d-nbj82             1/1     Running   0               9m4s
keycloak-0                         1/1     Running   1 (12m ago)     2d21h
order-service-77d4c47798-8zt8n     1/1     Running   4 (6m34s ago)   2d21h
pg-dc1-1                           1/1     Running   1 (12m ago)     2d23h
product-service-6958fcc4bd-xkm7z   1/1     Running   3 (6m12s ago)   2d21h

$ kubectl top pods -A (sorted by memory)
dc1-core             keycloak-0                                  3m    573Mi   
dc1-core             order-service-77d4c47798-8zt8n              2m    311Mi   
dc1-core             product-service-6958fcc4bd-xkm7z            3m    296Mi   
platform-operators   strimzi-cluster-operator-59669c9f77-xlwh8   7m    224Mi   
dc1-core             pg-dc1-1                                    9m    133Mi   
dc1-core             apisix-975c7b74d-nbj82                      4m    103Mi   
kube-system          local-path-provisioner-5d9d9885bc-4x86m     1m    57Mi    
platform-operators   cnpg-cloudnative-pg-8cf4dcc6-bptvp          2m    55Mi    
platform-operators   cass-operator-544dcc47cd-265bm              3m    53Mi    
kube-system          coredns-8db54c48d-z5vfq                     2m    40Mi    
kube-system          metrics-server-786d997795-lt9vb             4m    21Mi    
kube-system          svclb-apisix-external-6d937be0-kjws7        0m    0Mi     
kube-system          svclb-apisix-external-6d937be0-cnxj7        0m    0Mi     

$ docker stats --no-stream
k3d-multidc-serverlb cpu=0.00% mem=22.79MiB / 15.56GiB
k3d-multidc-agent-1 cpu=1.38% mem=85.62MiB / 15.56GiB
k3d-multidc-agent-0 cpu=3.12% mem=1.805GiB / 15.56GiB
k3d-multidc-server-0 cpu=10.05% mem=1.124GiB / 15.56GiB
registry.localhost cpu=0.00% mem=4.84MiB / 15.56GiB

$ free -m
               total       utilisé      libre     partagé tamp/cache   disponible
Mem:           15930        9803         408         178        5691        6126
```
