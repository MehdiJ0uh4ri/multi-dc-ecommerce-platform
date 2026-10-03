"""Seed the catalogue from DummyJSON through APISIX -> product-service.

Authenticates as the Keycloak service account `platform-seeder` (client credentials,
terraform/keycloak). product-service only requires an authenticated caller for writes
(docs/known-limits.md).

Idempotent: categories are matched by title and products by SKU, so a re-run only adds
what is missing.

The root category ROOT_CATEGORY is created by the Job's init container, not here:
product-service cannot create a category without a parent (upstream finding #11).

Environment:
  GATEWAY_URL, KEYCLOAK_URL, KEYCLOAK_REALM       platform endpoints
  SEEDER_CLIENT_ID, SEEDER_CLIENT_SECRET          service-account credentials
  DUMMYJSON_URL (https://dummyjson.com)           catalogue source
  DUMMYJSON_FILE                                  optional local copy of /products?limit=0
  SEED_PRODUCTS_LIMIT (0 = all 194)               cap for quick runs
  ROOT_CATEGORY (All), MAX_RPS (15), WAIT_TIMEOUT_S (900)
"""
import json
import logging
import sys
import time
from pathlib import Path

import requests

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from common import env, setup_logging  # noqa: E402
from common.api import ApiError, Platform  # noqa: E402

log = logging.getLogger("seed_products")


def load_catalogue(url, file, limit):
    if file:
        data = json.loads(Path(file).read_text())
    else:
        r = requests.get(f"{url.rstrip('/')}/products", timeout=60, params={
            "limit": 0, "select": "title,category,price,stock,sku,thumbnail",
        })
        r.raise_for_status()
        data = r.json()
    products = data["products"]
    return products[:limit] if limit else products


def category_title(slug):
    return slug.replace("-", " ").title()


def to_product(item, category_id):
    return {
        "productTitle": item["title"],
        "imageUrl": item.get("thumbnail"),
        "sku": item["sku"],
        "priceUnit": float(item["price"]),
        "quantity": int(item.get("stock", 0)),
        "category": {"categoryId": category_id},
    }


def wait_for_catalogue_api(platform, timeout):
    deadline = time.time() + timeout
    while True:
        try:
            return platform.list_categories()
        except ApiError as e:
            if time.time() > deadline:
                raise
            log.info("product-service not ready (%s), waiting", e)
            time.sleep(10)


def wait_for_client(tokens, timeout):
    """On a first build this Job starts before `make keycloak-config` creates the client."""
    deadline = time.time() + timeout
    while True:
        try:
            return tokens.get()
        except ApiError as e:
            if e.status not in (400, 401) or time.time() > deadline:
                raise
            log.info("Keycloak client not usable yet (%s); run `make keycloak-config`. Waiting", e.status)
            time.sleep(15)


def main():
    setup_logging()
    platform = Platform(env("GATEWAY_URL"), env("KEYCLOAK_URL"), env("KEYCLOAK_REALM", "ecommerce"),
                        max_rps=env("MAX_RPS", 15.0, float))
    tokens = platform.client_credentials(env("SEEDER_CLIENT_ID"), env("SEEDER_CLIENT_SECRET"))
    root_title = env("ROOT_CATEGORY", "All")
    wait_for_client(tokens, env("WAIT_TIMEOUT_S", 900, int))

    catalogue = load_catalogue(env("DUMMYJSON_URL", "https://dummyjson.com"),
                               env("DUMMYJSON_FILE", ""), env("SEED_PRODUCTS_LIMIT", 0, int))
    log.info("catalogue: %d products", len(catalogue))

    categories = {c["categoryTitle"]: c["categoryId"]
                  for c in wait_for_catalogue_api(platform, env("WAIT_TIMEOUT_S", 900, int))}
    root_id = categories.get(root_title)
    if root_id is None:
        sys.exit(f"root category '{root_title}' is missing; the init container should have created it")

    created_categories = 0
    for slug in sorted({item["category"] for item in catalogue}):
        title = category_title(slug)
        if title not in categories:
            categories[title] = platform.create_category(tokens, title, parent_id=root_id)["categoryId"]
            created_categories += 1

    existing_skus = {p.get("sku") for p in platform.list_products()}
    created = skipped = failed = 0
    for item in catalogue:
        if item["sku"] in existing_skus:
            skipped += 1
            continue
        try:
            platform.create_product(tokens, to_product(item, categories[category_title(item["category"])]))
            created += 1
        except ApiError as e:
            failed += 1
            log.error("product %s: %s", item["sku"], e)

    total = len(platform.list_products())
    # verify-phase4.5 reads this line.
    print(f"SUMMARY categories_created={created_categories} products_created={created} "
          f"products_skipped={skipped} products_failed={failed} products_total={total}", flush=True)
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
