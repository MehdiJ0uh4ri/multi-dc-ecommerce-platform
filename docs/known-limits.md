# Known limits

These are gaps we know about and chose not to fix yet. Each one names where it comes from, the risk, and when it gets fixed.

## Catalogue writes need only authentication (fix in Phase 5, with CI)

**Where it comes from:** `app/product-service/.../config/SecurityConfig.java`.

- GET on `/api/products/**` and `/api/categories/**` is public.
- Everything else only requires `.authenticated()`.
- `ProductController` and `CategoryController` have no `@PreAuthorize`. This covers POST, PUT and DELETE on both products and categories.
- APISIX's `product-catalog` route has no `openid-connect` plugin (`app/deploy/apisix/apisix.yaml`), so the gateway does not check anything either.

**Risk:** any valid token from the `ecommerce` realm can create, change or delete products and categories. That includes a shopper who just signed up through the public `/api/v1/auth/signup`, and the `platform-seeder` service account. The seeders rely on this today: `platform-seeder` has no realm roles.

**Fix:** needs a code change, so it waits for Phase 5 CI to build a patched image.
1. Add `@PreAuthorize("hasAuthority('ADMIN')")`, or a dedicated catalogue role, to the write endpoints.
2. Give that role to `platform-seeder` in `terraform/keycloak`.
3. Optionally add `openid-connect` to the APISIX route for defence in depth.

## APISIX rate limit is per client address

The global `limit-count` rule allows 1200 requests per 60 s per `remote_addr`.
- **In-cluster clients** (seeders, loadgen): each pod is limited to 20 requests per second, so the data tools cap themselves at `MAX_RPS` = 15.
- **Scaling:** raising loadgen throughput means more replicas, not a higher rate.
- **External clients:** they arrive with k3d-network addresses and each has its own budget.
