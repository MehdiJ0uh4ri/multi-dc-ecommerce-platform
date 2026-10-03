# Minimal test profile: smallest deployment that still runs the end-to-end check
# (Keycloak token -> APISIX -> POST /api/carts -> POST /api/orders -> PostgreSQL).
#   make tf-apply-minimal      (terraform apply -var-file=profiles/minimal.tfvars)
# Kept: operators, PostgreSQL, Keycloak, APISIX, product-service, order-service.
# Off:  Kafka (+ Kafka Connect/Debezium), Cassandra, auth/payment/inventory/shipping/tax,
#       the whole DC2 (Phase 4), observability (Phase 6) and Chaos Mesh (Phase 7).
# Phase 4.5: only seed-products (needs product-service + Keycloak); the Olist replay and
#       loadgen need auth/payment-service.
enable_kafka         = false
enable_cdc           = false
enable_cassandra     = false
dc1_services         = ["product-service", "order-service"]
enable_dc2           = false
enable_observability = false
enable_chaos         = false
dc1_pg_instances     = 1
enable_seed_orders   = false
enable_loadgen       = false
