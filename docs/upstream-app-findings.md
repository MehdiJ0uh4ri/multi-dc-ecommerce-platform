# Findings about the upstream app (commit 394b34b)

These facts were read from a shallow clone of the upstream repo. Each section names the command or files it came from. They affect later phases.

## Data stores per service

Source: `pom.xml` artifactIds per service, and the service `environment` blocks in `docker-compose.yml`.

| Service              | Stores it uses                                  |
|----------------------|-------------------------------------------------|
| auth-service         | PostgreSQL, Keycloak                             |
| product, order, shipping, inventory, tax | PostgreSQL                   |
| payment-service      | PostgreSQL, Kafka                               |
| notification-service | PostgreSQL, Kafka, SMTP                          |
| favourite, rating, promotion | PostgreSQL                               |
| media-service        | PostgreSQL, S3 (RustFS)                          |
| search-service       | Elasticsearch, Kafka                             |

Consequences:

1. **No service uses MongoDB, Cassandra or RabbitMQ.** They will only be "wired in" if we build that wiring ourselves, for example Kafka Connect sinks to Mongo and Cassandra, or a Kafka→RabbitMQ bridge for notifications. Otherwise they sit idle.
2. **The DC2 services rating, favourite, promotion and media need PostgreSQL.** They need either a Postgres in DC2 or an explicit cross-namespace NetworkPolicy to DC1's Postgres. This has to be decided before Phase 1's NetworkPolicies.
3. **There is no `api-gateway` service.** The gateway is Apache APISIX (`deploy/apisix`, `k8s/gateway`), and tokens come from Keycloak (`docker/keycloak/import`). Phase 3 therefore deploys APISIX and Keycloak.
4. **order-service mentions Kafka only in `application.yml`.** No source file under `order-service/src` matches `kafka`. The Kafka producers found are payment-service, which publishes to `SUCCESSFUL` (see #9), and the profile-onboarding flow. Phase 3's check that an order publishes a Kafka event will probably need Debezium CDC on the orders table, or a check of payment events instead. Not yet verified at runtime.

## Images and CI

Images are published to `ghcr.io/hoangtien2k3/<service>:latest`. They are built with Maven and Jib in `.github/workflows/_build-service.yml`, on Java 21. Health and metrics are exposed at `/actuator/health` and `/actuator/prometheus`, per the README.

## Host capacity

Commands: `nproc`, `free -g`.

The host has 4 CPUs and 15 GiB RAM, with about 6 GiB available when checked. Twelve or more Spring Boot JVMs plus Kafka, two Elasticsearch instances (search and ELK), Cassandra, MongoDB, Jenkins and Prometheus will not fit at once. Later phases need tight JVM and heap limits, single replicas, and probably one shared Elasticsearch or a scale-down per phase.

## Runtime findings (Phase 3 apply, 2026-09-15)

5. **tax-service cannot start.** Spring fails with `Parameter 0 of constructor in com.ecommerce.tax.service.LocationService required a bean of type 'org.springframework.web.client.RestClient'`.
   - In the source, `LocationService` injects `RestClient`, but tax-service only defines `ServiceUrlConfig`, `DatabaseAutoConfig` and `SecurityConfig`. common-spring's `RestClientAutoConfiguration` only provides `RestClient.Builder`.
   - The ghcr image `sha256:3698b417…` was created at 2026-08-22T02:43Z, two minutes after the pinned commit `394b34b`, so the image matches this source.
   - No configuration value can create the bean, so tax-service is disabled (`enabled: false` in `helm-values/dc1-core/services.yaml`). Fixing it means patching the code and building an image, which is the Phase 5 CI path.
6. **order-service's schema migration creates no tables.** Its changelog only runs `SELECT 1`, and its own default is `ddl-auto: validate`. It depends on `SPRING_JPA_HIBERNATE_DDL_AUTO=update`, which upstream sets in `k8s/configmap.yaml` and this platform sets too.
7. **search-service cannot index products.**
   - When a product changes, `ProductSyncDataService` calls `GET {ecommerce.services.product}/storefront/products-es/{id}` on product-service.
   - product-service has no such endpoint. Its routes are `/api/products`, `/api/categories`, `/{productId}`, `/paging` and `/paging-and-sorting`, and `products-es` appears nowhere in its source.
   - The pipeline up to search-service is built and verified: CDC, then MirrorMaker 2, then the DC2 topic, then the consumer. The final index write needs an upstream code change.
8. **The product CDC contract does not match the schema.** search-service expects topic `dbproduct.public.product` and key `id`. The table is `products` with key `product_id`. This is bridged by configuration (ADR-021).
9. **The payment topic is `SUCCESSFUL`.** `PaymentServiceImpl.save()` (behind `POST /api/payments`) publishes to `KafkaConstant.STATUS_PAYMENT_SUCCESSFUL = "SUCCESSFUL"`, and notification-service listens on the same name. `paymentCreated`, `paymentCompleted` and `paymentRequest` are declared but never produced. Phase 4's MirrorMaker 2 pattern, RabbitMQ sink and verify script first used the declared names and were corrected on 2026-09-18. A `PaymentDto` carries `orderId`, `userId`, `isPayed` and `paymentStatus`, but no amount.
10. **No geography anywhere.** Order, payment and shipping DTOs have no country or address fields.
11. **product-service cannot create a root category.** `CategoryMappingHelper.map(CategoryDto)` always builds a `parentCategory`: an empty, unsaved `Category` when the request has none. `Category.parentCategory` is a `@ManyToOne` with no cascade, so saving should fail with Hibernate's "references an unsaved transient instance", which `CategoryServiceImpl.save` does not catch. The seed Job inserts the root category with SQL instead (ADR-032). This was derived from reading the code and has not yet been observed at runtime.
12. **Catalogue writes need only authentication.** Tracked in [known-limits.md](known-limits.md).
