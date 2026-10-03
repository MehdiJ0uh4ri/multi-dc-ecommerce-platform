# Phase 4.5: data layer (seed data and live traffic)

Phase 4.5 fills the platform with realistic data and keeps traffic flowing, so that CDC, MirrorMaker 2, the DC2 sinks and the Phase 5a fraud detection have something real to work on. All three tools run from one image, `data-tools/`, deployed by `charts/data-tools` in `dc1-core`. Decisions are recorded in ADR-030 to ADR-033.

| Workload | Kind | What it does |
|---|---|---|
| `seed-products-<hash>` | Job | Loads the DummyJSON catalogue (194 products, 24 categories) through APISIX into product-service, as the `platform-seeder` service account. Idempotent. |
| `seed-orders-<hash>` | Job | Replays prepared Olist orders in compressed time, each from a Faker shopper signed up through auth-service. Runs only when `data-tools/data/olist-replay.jsonl.gz` exists. Not idempotent, never retried. |
| `loadgen` | Deployment | Poisson traffic: 95 % normal orders and 5 % labelled fraud patterns. Every setting comes from env (`helm-values/dc1-core/data-tools.yaml`). Exposes metrics on :9000. |

## Data flow

```
DummyJSON ──► seed-products ──(client credentials: platform-seeder)──► APISIX ─► product-service ─► pg-dc1 productservice
                 └─ init container: INSERT root category "All" (psql, pg-dc1)               │ Debezium (products-cdc)
                                                                                             ▼
Olist (host) ─make olist-prepare─► ConfigMap olist-replay ─► seed-orders ┐          kafka-dc1: dbproduct.public.product
                                                                          ├─► APISIX ─► auth-service ─► Keycloak (sign-up, role USER)
                                         loadgen (Poisson, fraud mix) ────┘          ├─► order-service ─► pg-dc1 ─► Debezium ─► dborder.public.orders
                                              │                                      └─► payment-service ─► kafka-dc1: SUCCESSFUL
                                              └── confluent-kafka ─────────────────────────────────────────► kafka-dc1: order-context
                                                                                                                     │
                                                              MirrorMaker 2 (dbproduct.*, dborder.*, SUCCESSFUL, order-context)
                                                                                                                     ▼
                                                   kafka-dc2 ─► MongoDB analytics.products / analytics.orders, RabbitMQ payments.audit,
                                                               and Phase 5a fraud detection (orders ⨝ SUCCESSFUL ⨝ order-context)
```

Shoppers are real platform users:
1. `POST /api/v1/auth/signup` creates the Keycloak user, with realm role `USER`, and the auth-service row.
2. `ecommerce-client` issues a password-grant token.
3. `GET /api/v1/users/me` returns the numeric id that carts and payments carry.
4. Orders need a cart (`POST /api/carts` once per shopper), then `POST /api/orders`.
5. `POST /api/payments` publishes to `SUCCESSFUL`.

## The `order-context` event (ADR-030)

Topic `order-context` on kafka-dc1. Key: orderId. Header `scenario` = `normal` | `rapid_repeat` | `geo_mismatch` | `high_value_new_account`.

```json
{"orderId": 123, "userId": 45, "productId": 7, "orderFee": 59.97,
 "shippingCountry": "FR", "billingCountry": "FR", "accountCreated": false,
 "source": "loadgen", "ts": "2026-09-18T10:00:00.123Z"}
```

The `scenario` header is **ground truth**. It is for measuring detection (precision and recall), and detectors must not read it. Olist orders are always `BR`/`BR` with `source: seed`.

## Traffic model (loadgen)

Arrivals are a Poisson process: exponential gaps with mean `1/LOADGEN_RATE`. Each arrival is one scenario, and `LOADGEN_FRAUD_MIX` splits the fraud share between patterns.

| Scenario | Default share | Behaviour | Signal for Phase 5a |
|---|---|---|---|
| normal | 95 % | A pool shopper (`lgpool00000`–`lgpool00049`, fixed home country) orders 1–3 units. 90 % are paid. | none |
| rapid_repeat | ≈1.67 % | Same pool shopper, 6 paid orders in 20 s | velocity per userId |
| geo_mismatch | ≈1.67 % | Paid order, shipping country ≠ billing (home) country | `order-context` countries |
| high_value_new_account | ≈1.67 % | Brand-new account, one paid order ≥ max(2000, 20 × unit price) | `orderFee` from the orders CDC, joined to `SUCCESSFUL`; `accountCreated` |

Payments carry no amount (upstream finding #9). Amount rules therefore join `SUCCESSFUL` (by orderId) with `orderFee` from `dborder.public.orders`, or with `order-context`.

`python loadgen/loadgen.py simulate --seconds 600` prints the statistics offline. Example at 1 arrival per second: 585 arrivals, a 4.4 % fraud share. The exact fraud share converges at larger N; the unit test checks 5.00 % ± 0.5 % over 100 k arrivals.

Load control:
- **Per-pod cap:** each pod calls APISIX at most `MAX_RPS` = 15 times per second, below the gateway's 20/s per address (see [known-limits.md](known-limits.md)).
- **Bounded backlog:** when all workers are busy, arrivals are dropped and counted in `loadgen_arrivals_dropped_total`, rather than queued without limit.

Metrics:
- `loadgen_orders_total{scenario,result}`
- `loadgen_payments_total{scenario}`
- `loadgen_http_requests_total{endpoint,code}`
- `loadgen_http_request_duration_seconds`
- `loadgen_arrivals_total`
- `loadgen_scenarios_in_flight`

Prometheus scrapes them through the `loadgen` PodMonitor when observability is enabled.

## Run it

```bash
make secrets               # adds dc1_keycloak_seeder_client + data_tools_user_password (keeps existing ones)
make data-tools-test       # unit tests inside the image, no cluster needed
make data-tools-image      # build + push localhost:5000/platform/data-tools:$(cat data-tools/VERSION)
# optional: Olist CSVs from kaggle.com/datasets/olistbr/brazilian-ecommerce into data-tools/data/
make olist-prepare         # ARGS="--start 2017-11-01 --limit 5000"
make tf-apply              # data-tools release (seed-products waits up to 15 min for the Keycloak client)
make keycloak-config       # creates platform-seeder (terraform/keycloak) through a port-forward
make verify-phase4.5       # VERIFY_WAIT_SEED_ORDERS=1 to wait for the whole replay
```

**Order matters on a first build.** The image must be in the registry before `tf-apply`: the loadgen Deployment rollout waits for it.

`make keycloak-config` needs Keycloak running, which only happens during the first `tf-apply`. seed-products therefore waits up to 15 minutes for the client to appear. If it gave up, recreate the release:

```bash
terraform -chdir=terraform apply -replace='helm_release.data_tools[0]'
```

**What runs depends on the profile.**

| Profile | seed-products | seed-orders | loadgen |
|---|---|---|---|
| minimal | yes (needs product-service and Keycloak) | no | no |
| default | yes | yes, if the replay file exists | yes |

Terraform also turns seed-orders and loadgen off when auth-, order- or payment-service is not deployed (output `data_tools`).

## Resources

Requests and limits come from `helm-values/dc1-core/data-tools.yaml`; runtime usage is not measured yet.

| Workload | Requests | Limits | Runs |
|---|---|---|---|
| seed-products (+ init 32 Mi) | 50m / 96 Mi | 500m / 256 Mi | once |
| seed-orders | 100m / 128 Mi | 1 / 384 Mi | once per replay file (5000 orders ≈ 30–45 min at 15 req/s) |
| loadgen | 50m / 96 Mi | 500m / 256 Mi | always |

By a hand sum of the DC1 values files, the dc1-core quota (9 Gi requests, 16 Gi limits) has room; this is an estimate, not a measurement. The real headroom is on the host, which Phase 4 already exceeds.

## Tradeoffs

- **Seeding through the gateway, not SQL.** It is slower (limited by the per-address rate) but exercises auth, routing, validation and CDC exactly like production traffic. The only direct write is the root category (upstream finding #11).
- **One shared shopper password.** Every synthetic shopper has the same password (`data-tools-users` Secret). They are synthetic accounts in a local realm; per-user secrets would add state without adding realism.
- **Ground truth in a header, not a field.** Detectors see the same payload a production system would. Evaluation can still join on the truth.
- **ConfigMap, not a volume, for the dataset.** There is no PVC or copy step, and Terraform owns it. The catch is the 900 KiB cap: a bigger replay would need an object store (RustFS is in DC2) or a PVC.
