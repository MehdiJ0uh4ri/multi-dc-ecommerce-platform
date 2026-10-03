"""Replay Olist orders through the platform in compressed time.

Two steps, because the dataset stays on the operator's machine (CC BY-NC-SA 4.0, needs a
Kaggle login, gitignored under data-tools/data/):

  prepare  (host, `make olist-prepare`)
      Joins the Olist CSVs into a compact, time-sorted file data-tools/data/olist-replay.jsonl.gz.
      Terraform ships it to the cluster as a ConfigMap, so it must stay under 900 KiB.

  replay   (Kubernetes Job seed-orders)
      For each order, at (purchase time - first purchase time) / SEED_TIME_COMPRESSION:
        1. the Olist customer becomes a Faker (pt_BR) shopper, signed up through
           APISIX -> auth-service -> Keycloak on first use;
        2. POST /api/carts (once per shopper), POST /api/orders, POST /api/payments;
        3. an order-context event (country BR) on kafka-dc1.
      Each order uses the seeded product whose price is closest to the Olist item price,
      so orderFee / unit price stays realistic (the Phase 5a amount rule relies on it).

Replay environment:
  GATEWAY_URL, KEYCLOAK_URL, KEYCLOAK_REALM, PUBLIC_CLIENT_ID, DATA_TOOLS_USER_PASSWORD
  KAFKA_BOOTSTRAP, ORDER_CONTEXT_TOPIC, ORDER_CONTEXT_ENABLED (true)
  REPLAY_FILE (/data/olist-replay.jsonl.gz), SEED_ORDERS_LIMIT (0 = whole file)
  SEED_TIME_COMPRESSION (720: one Olist day = 2 min), SEED_WORKERS (6), MAX_RPS (15)

When the gateway's rate limit is slower than the schedule, the replay falls behind and
logs the lag; it never drops orders.
"""
import argparse
import bisect
import csv
import gzip
import hashlib
import json
import logging
import random
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from common import env, env_bool, phone_number, setup_logging  # noqa: E402
from common.accounts import Accounts, user_password  # noqa: E402
from common.api import ApiError, Platform  # noqa: E402
from common.order_context import OrderContextPublisher, build_event  # noqa: E402

log = logging.getLogger("seed_orders")

TIME_FORMAT = "%Y-%m-%d %H:%M:%S"
MAX_REPLAY_BYTES = 900 * 1024
OLIST_FILES = {
    "orders": ("olist_orders_dataset.csv",
               {"order_id", "customer_id", "order_status", "order_purchase_timestamp"}),
    "items": ("olist_order_items_dataset.csv", {"order_id", "product_id", "price", "freight_value"}),
    "customers": ("olist_customers_dataset.csv", {"customer_id", "customer_unique_id", "customer_state"}),
    "payments": ("olist_order_payments_dataset.csv", {"order_id", "payment_type", "payment_value"}),
}


# --- prepare ------------------------------------------------------------------
def read_csv(directory, key):
    name, required = OLIST_FILES[key]
    path = Path(directory) / name
    if not path.exists():
        sys.exit(f"{path} not found. Download the Olist dataset "
                 "(kaggle.com/datasets/olistbr/brazilian-ecommerce) into data-tools/data/.")
    with path.open(newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        missing = required - set(reader.fieldnames or [])
        if missing:
            sys.exit(f"{name}: missing columns {sorted(missing)}")
        yield from reader


def short_hash(value):
    return int(hashlib.sha1(value.encode()).hexdigest()[:8], 16)


def prepare(args):
    start = datetime.strptime(args.start, "%Y-%m-%d")
    orders = []
    for row in read_csv(args.input, "orders"):
        if row["order_status"] in ("canceled", "unavailable") or not row["order_purchase_timestamp"]:
            continue
        ts = datetime.strptime(row["order_purchase_timestamp"], TIME_FORMAT)
        if ts >= start:
            orders.append((ts, row["order_id"], row["customer_id"]))
    orders.sort()
    orders = orders[:args.limit]
    wanted = {o[1] for o in orders}

    customers = {r["customer_id"]: (r["customer_unique_id"], r["customer_state"])
                 for r in read_csv(args.input, "customers")}
    items, fees = {}, {}
    for r in read_csv(args.input, "items"):
        if r["order_id"] in wanted:
            items.setdefault(r["order_id"], (short_hash(r["product_id"]), float(r["price"])))
            fees[r["order_id"]] = fees.get(r["order_id"], 0.0) + float(r["price"]) + float(r["freight_value"])
    payments = {}
    for r in read_csv(args.input, "payments"):
        if r["order_id"] in wanted:
            value, kind = payments.get(r["order_id"], (0.0, r["payment_type"]))
            payments[r["order_id"]] = (value + float(r["payment_value"]), kind)

    records = []
    for ts, order_id, customer_id in orders:
        if order_id not in items or customer_id not in customers:
            continue
        unique_id, state = customers[customer_id]
        paid, kind = payments.get(order_id, (0.0, ""))
        product_hash, item_price = items[order_id]
        records.append({"o": order_id, "t": ts.strftime(TIME_FORMAT), "c": unique_id, "s": state,
                        "p": product_hash, "ip": item_price, "f": round(fees[order_id], 2),
                        "pv": round(paid, 2), "pt": kind})

    payload = gzip.compress("\n".join(json.dumps(r, separators=(",", ":")) for r in records).encode(), 9)
    if len(payload) > MAX_REPLAY_BYTES:
        sys.exit(f"{len(payload)} bytes compressed is over the {MAX_REPLAY_BYTES}-byte ConfigMap budget; "
                 "lower --limit")
    Path(args.output).write_bytes(payload)
    span = f"{records[0]['t']} .. {records[-1]['t']}" if records else "empty"
    print(f"wrote {len(records)} orders ({span}), {len(payload)} bytes -> {args.output}")


# --- replay -------------------------------------------------------------------
def load_replay(path, limit):
    with gzip.open(path, "rt", encoding="utf-8") as f:
        records = [json.loads(line) for line in f if line.strip()]
    records.sort(key=lambda r: r["t"])
    return records[:limit] if limit else records


def schedule(records, compression):
    """Seconds after replay start at which each record is due."""
    if not records:
        return []
    t0 = datetime.strptime(records[0]["t"], TIME_FORMAT)
    return [(datetime.strptime(r["t"], TIME_FORMAT) - t0).total_seconds() / compression for r in records]


def closest_product(catalogue, price, tie_break):
    """catalogue: [(price, productId)] sorted by price. Among equally close products,
    tie_break (a stable hash) picks one, so replays are deterministic."""
    i = bisect.bisect_left(catalogue, (price, -1))
    candidates = catalogue[max(0, i - 1):i + 1]
    best = min(abs(c[0] - price) for c in candidates)
    ties = [c for c in candidates if abs(c[0] - price) == best]
    return ties[tie_break % len(ties)][1]


def shopper_profile(unique_id, attempt=0):
    """Deterministic Faker shopper for one Olist customer_unique_id."""
    from faker import Faker

    fake = Faker("pt_BR")
    fake.seed_instance(int(unique_id[:8], 16))
    username = "ol" + unique_id[:10]
    full_name = fake.name()
    return {
        "fullName": full_name if len(full_name) >= 6 else (full_name + " Silva"),
        "username": username,
        "email": f"{username}@olist.example.com",
        "gender": random.Random(unique_id).choice(["MALE", "FEMALE"]),
        # Olist shoppers use prefix 08; the load generator uses 07 and 09.
        "phone": phone_number("08", short_hash(unique_id) + attempt * 7919),
    }


class Replay:
    def __init__(self, platform, accounts, publisher, products):
        self.platform = platform
        self.accounts = accounts
        self.publisher = publisher
        self.products = products
        self.lock = threading.Lock()
        self.done = self.failed = self.paid = 0

    def run_one(self, record):
        try:
            account, created = self.accounts.ensure(lambda attempt: shopper_profile(record["c"], attempt))
            cart_id = self.accounts.cart(account)
            product_id = closest_product(self.products, record.get("ip", 0.0), record["p"])
            order = self.platform.create_order(account.tokens, cart_id, product_id, record["f"],
                                               f"olist:{record['o']}")
            order_id = int(order["orderId"])
            self.publisher.publish(build_event(order_id, account.user_id, product_id, record["f"],
                                               "BR", "BR", "seed", account_created=created), "normal")
            if record.get("pv", 0) > 0:
                self.platform.create_payment(account.tokens, order_id, account.user_id)
                with self.lock:
                    self.paid += 1
            with self.lock:
                self.done += 1
        except (ApiError, KeyError, ValueError) as e:
            with self.lock:
                self.failed += 1
            log.error("order %s: %s", record["o"], e)


def wait_for_products(platform, timeout):
    deadline = time.time() + timeout
    while True:
        try:
            products = sorted((float(p["priceUnit"] or 0), p["productId"]) for p in platform.list_products())
            if products:
                return products
            log.info("catalogue is empty, waiting for seed-products")
        except ApiError as e:
            log.info("product-service not ready (%s)", e)
        if time.time() > deadline:
            sys.exit("no products after waiting; run seed-products first")
        time.sleep(15)


def replay(args):
    setup_logging()
    records = load_replay(env("REPLAY_FILE", "/data/olist-replay.jsonl.gz"), env("SEED_ORDERS_LIMIT", 0, int))
    compression = env("SEED_TIME_COMPRESSION", 720.0, float)
    workers = env("SEED_WORKERS", 6, int)

    platform = Platform(env("GATEWAY_URL"), env("KEYCLOAK_URL"), env("KEYCLOAK_REALM", "ecommerce"),
                        max_rps=env("MAX_RPS", 15.0, float))
    accounts = Accounts(platform, env("PUBLIC_CLIENT_ID", "ecommerce-client"),
                        user_password(env("DATA_TOOLS_USER_PASSWORD")))
    publisher = OrderContextPublisher(env("KAFKA_BOOTSTRAP", "kafka-dc1-kafka-bootstrap:9092"),
                                      env("ORDER_CONTEXT_TOPIC", "order-context"),
                                      enabled=env_bool("ORDER_CONTEXT_ENABLED", True))
    job = Replay(platform, accounts, publisher, wait_for_products(platform, env("WAIT_TIMEOUT_S", 1800, int)))

    shoppers = len({r["c"] for r in records})
    due = schedule(records, compression)
    log.info("replaying %d orders from %d shoppers over %.0f s (compression %gx)",
             len(records), shoppers, due[-1] if due else 0, compression)

    slots = threading.BoundedSemaphore(workers * 2)
    started = time.monotonic()
    with ThreadPoolExecutor(max_workers=workers) as pool:
        for n, (record, at) in enumerate(zip(records, due), 1):
            delay = started + at - time.monotonic()
            if delay > 0:
                time.sleep(delay)
            slots.acquire()
            future = pool.submit(job.run_one, record)
            future.add_done_callback(lambda _: slots.release())
            if n % 100 == 0:
                lag = max(0.0, time.monotonic() - started - at)
                print(f"PROGRESS submitted={n}/{len(records)} replayed={job.done} failed={job.failed} "
                      f"lag_s={lag:.0f}", flush=True)
    publisher.flush()

    # verify-phase4.5 reads this line.
    print(f"SUMMARY orders_replayed={job.done} payments={job.paid} failed={job.failed} "
          f"shoppers={shoppers} seconds={time.monotonic() - started:.0f}", flush=True)
    sys.exit(1 if job.failed > max(5, 0.05 * len(records)) else 0)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("prepare", help="Olist CSVs -> compact replay file (host)")
    p.add_argument("--input", default="data-tools/data")
    p.add_argument("--output", default="data-tools/data/olist-replay.jsonl.gz")
    p.add_argument("--start", default="2017-11-01", help="first purchase date to include (YYYY-MM-DD)")
    p.add_argument("--limit", type=int, default=5000)
    sub.add_parser("replay", help="replay the file through the platform (Job)")
    args = parser.parse_args()
    prepare(args) if args.command == "prepare" else replay(args)


if __name__ == "__main__":
    main()
