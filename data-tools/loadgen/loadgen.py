"""Continuous shopper traffic with a labelled share of fraud patterns.

Arrivals form a Poisson process (exponential gaps, mean rate LOADGEN_RATE per second).
Each arrival is one scenario:

  normal (1 - LOADGEN_FRAUD_RATIO)
      A pool shopper orders 1-3 units of a random product. Shipping and billing are the
      shopper's home country. Paid with probability LOADGEN_PAY_RATIO.
  rapid_repeat
      One pool shopper places RAPID_REPEAT_COUNT paid orders within RAPID_REPEAT_WINDOW_S.
  geo_mismatch
      A normal paid order whose shipping country differs from the billing (home) country.
  high_value_new_account
      A shopper signed up seconds ago places one paid order worth HIGH_VALUE_MULTIPLIER
      times a normal basket, at least HIGH_VALUE_MIN_FEE.

The fraud share is split across patterns by LOADGEN_FRAUD_MIX (weights). Every order
goes APISIX -> order-service (-> payment-service), and an order-context event carries
the countries and, in a Kafka header, the scenario (ground truth; see
common/order_context.py).

Metrics on :METRICS_PORT/metrics (Prometheus). `python loadgen.py simulate` prints the
arrival and scenario statistics without touching the network.

Environment (defaults in brackets):
  GATEWAY_URL, KEYCLOAK_URL, KEYCLOAK_REALM [ecommerce], PUBLIC_CLIENT_ID [ecommerce-client]
  DATA_TOOLS_USER_PASSWORD, KAFKA_BOOTSTRAP, ORDER_CONTEXT_TOPIC [order-context]
  ORDER_CONTEXT_ENABLED [true], MAX_RPS [15], METRICS_PORT [9000]
  LOADGEN_RATE [1.0], LOADGEN_FRAUD_RATIO [0.05],
  LOADGEN_FRAUD_MIX [rapid_repeat=1,geo_mismatch=1,high_value_new_account=1]
  LOADGEN_USERS [50], LOADGEN_PAY_RATIO [0.9], LOADGEN_WORKERS [16], LOADGEN_DURATION_S [0 = forever]
  LOADGEN_COUNTRIES [FR=40,DE=20,ES=15,IT=10,NL=5,BE=5,PT=5], LOADGEN_SEED [random]
  RAPID_REPEAT_COUNT [6], RAPID_REPEAT_WINDOW_S [20]
  HIGH_VALUE_MULTIPLIER [20], HIGH_VALUE_MIN_FEE [2000]
"""
import argparse
import collections
import logging
import random
import signal
import string
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from common import env, env_bool, phone_number, setup_logging  # noqa: E402

log = logging.getLogger("loadgen")

NORMAL = "normal"
FRAUD_PATTERNS = ("rapid_repeat", "geo_mismatch", "high_value_new_account")


# --- pure scheduling logic (unit-tested, used by `simulate`) ------------------
def parse_weights(text, allowed=None):
    weights = {}
    for part in filter(None, (p.strip() for p in text.split(","))):
        name, _, value = part.partition("=")
        name = name.strip()
        if allowed is not None and name not in allowed:
            raise ValueError(f"unknown name {name!r}; expected one of {sorted(allowed)}")
        weights[name] = float(value or 1)
    if not weights or sum(weights.values()) <= 0:
        raise ValueError(f"no positive weights in {text!r}")
    return weights


def weighted_choice(rng, weights):
    return rng.choices(list(weights), weights=list(weights.values()), k=1)[0]


def choose_scenario(rng, fraud_ratio, fraud_mix):
    return weighted_choice(rng, fraud_mix) if rng.random() < fraud_ratio else NORMAL


def next_gap(rng, rate):
    """Exponential inter-arrival time: arrivals form a Poisson process of `rate` per second."""
    return rng.expovariate(rate)


def mismatched_country(rng, countries, home):
    return weighted_choice(rng, {c: w for c, w in countries.items() if c != home})


def basket(rng, price):
    quantity = rng.choices((1, 2, 3), weights=(70, 20, 10), k=1)[0]
    return quantity * price


def high_value_fee(price, multiplier, minimum):
    return max(minimum, price * multiplier)


@dataclass(frozen=True)
class Config:
    rate: float
    fraud_ratio: float
    fraud_mix: dict
    users: int
    pay_ratio: float
    workers: int
    duration: float
    countries: dict
    repeat_count: int
    repeat_window: float
    high_value_multiplier: float
    high_value_min_fee: float
    seed: int

    @classmethod
    def from_env(cls):
        cfg = cls(
            rate=env("LOADGEN_RATE", 1.0, float),
            fraud_ratio=env("LOADGEN_FRAUD_RATIO", 0.05, float),
            fraud_mix=parse_weights(env("LOADGEN_FRAUD_MIX", "rapid_repeat=1,geo_mismatch=1,high_value_new_account=1"),
                                    FRAUD_PATTERNS),
            users=env("LOADGEN_USERS", 50, int),
            pay_ratio=env("LOADGEN_PAY_RATIO", 0.9, float),
            workers=env("LOADGEN_WORKERS", 16, int),
            duration=env("LOADGEN_DURATION_S", 0.0, float),
            countries=parse_weights(env("LOADGEN_COUNTRIES", "FR=40,DE=20,ES=15,IT=10,NL=5,BE=5,PT=5")),
            repeat_count=env("RAPID_REPEAT_COUNT", 6, int),
            repeat_window=env("RAPID_REPEAT_WINDOW_S", 20.0, float),
            high_value_multiplier=env("HIGH_VALUE_MULTIPLIER", 20.0, float),
            high_value_min_fee=env("HIGH_VALUE_MIN_FEE", 2000.0, float),
            seed=env("LOADGEN_SEED", random.SystemRandom().randrange(2**31), int),
        )
        if cfg.rate <= 0 or not 0 <= cfg.fraud_ratio <= 1 or not 0 <= cfg.pay_ratio <= 1:
            raise ValueError("LOADGEN_RATE must be > 0; LOADGEN_FRAUD_RATIO and LOADGEN_PAY_RATIO in [0, 1]")
        if len(cfg.countries) < 2:
            raise ValueError("LOADGEN_COUNTRIES needs at least two countries for geo_mismatch")
        return cfg


def simulate(cfg, seconds):
    rng = random.Random(cfg.seed)
    t, counts, gaps = 0.0, collections.Counter(), []
    while True:
        gap = next_gap(rng, cfg.rate)
        t += gap
        if t > seconds:
            break
        gaps.append(gap)
        counts[choose_scenario(rng, cfg.fraud_ratio, cfg.fraud_mix)] += 1
    total = sum(counts.values())
    orders = counts[NORMAL] + counts["geo_mismatch"] + counts["high_value_new_account"] \
        + counts["rapid_repeat"] * cfg.repeat_count
    print(f"arrivals={total} in {seconds:.0f}s rate={total / seconds:.3f}/s "
          f"mean_gap={sum(gaps) / max(1, len(gaps)):.3f}s (expected {1 / cfg.rate:.3f}s)")
    for name in (NORMAL,) + FRAUD_PATTERNS:
        print(f"  {name:24s} {counts[name]:7d}  {counts[name] / max(1, total):.4f}")
    print(f"fraud share of arrivals={1 - counts[NORMAL] / max(1, total):.4f} (target {cfg.fraud_ratio}); "
          f"orders={orders}")
    return counts


# --- live traffic ---------------------------------------------------------------
class Metrics:
    def __init__(self, port):
        from prometheus_client import Counter, Gauge, Histogram, start_http_server

        self.arrivals = Counter("loadgen_arrivals_total", "Scenario arrivals", ["scenario"])
        self.dropped = Counter("loadgen_arrivals_dropped_total", "Arrivals dropped because all workers were busy")
        self.orders = Counter("loadgen_orders_total", "Orders placed", ["scenario", "result"])
        self.payments = Counter("loadgen_payments_total", "Payments made", ["scenario"])
        self.requests = Counter("loadgen_http_requests_total", "Gateway requests", ["endpoint", "code"])
        self.latency = Histogram("loadgen_http_request_duration_seconds", "Gateway request latency", ["endpoint"])
        self.in_flight = Gauge("loadgen_scenarios_in_flight", "Scenarios being executed")
        start_http_server(port)

    def on_response(self, endpoint, status, seconds):
        self.requests.labels(endpoint, str(status)).inc()
        self.latency.labels(endpoint).observe(seconds)


class LoadGenerator:
    def __init__(self, cfg, platform, accounts, publisher, metrics):
        self.cfg = cfg
        self.platform = platform
        self.accounts = accounts
        self.publisher = publisher
        self.metrics = metrics
        self.rng = random.Random(cfg.seed)
        self.rng_lock = threading.Lock()
        self.products = []
        self.products_loaded = 0.0
        self.products_lock = threading.Lock()
        self.run_id = "".join(random.Random(cfg.seed).choices(string.ascii_lowercase + string.digits, k=6))
        self.new_accounts = 0
        self.stop = threading.Event()

    def rand(self, fn, *args):
        with self.rng_lock:
            return fn(self.rng, *args)

    # catalogue, refreshed every 5 minutes
    def product(self):
        with self.products_lock:
            if not self.products or time.time() - self.products_loaded > 300:
                listed = [(p["productId"], float(p["priceUnit"] or 0)) for p in self.platform.list_products()]
                self.products = [p for p in listed if p[1] > 0] or self.products
                self.products_loaded = time.time()
            if not self.products:
                raise RuntimeError("catalogue is empty; run seed-products first")
            return self.rand(lambda rng: rng.choice(self.products))

    def pool_account(self):
        index = self.rand(lambda rng: rng.randrange(self.cfg.users))
        username = f"lgpool{index:05d}"
        account, _ = self.accounts.ensure(lambda attempt: {
            "fullName": f"Loadgen Shopper {index:05d}",
            "username": username,
            "email": f"{username}@loadgen.example.com",
            "gender": "MALE" if index % 2 else "FEMALE",
            "phone": phone_number("09", index + attempt * 100_003),
        })
        if account.country is None:
            account.country = weighted_choice(random.Random(username), self.cfg.countries)
        return account

    def fresh_account(self):
        with self.rng_lock:
            self.new_accounts += 1
            n = self.new_accounts
        username = f"lgnew{self.run_id}{n:06d}"
        account, created = self.accounts.ensure(lambda attempt: {
            "fullName": f"Loadgen Newcomer {n:06d}",
            "username": username,
            "email": f"{username}@loadgen.example.com",
            "gender": "FEMALE" if n % 2 else "MALE",
            "phone": phone_number("07", self.rand(lambda rng: rng.randrange(10**8))),
        })
        account.country = self.rand(weighted_choice, self.cfg.countries)
        return account, created

    def place(self, scenario, account, fee_for, shipping, pay, account_created=False):
        from common.api import ApiError
        from common.order_context import build_event

        try:
            product_id, price = self.product()
            fee = fee_for(price)
            cart_id = self.accounts.cart(account)
            order = self.platform.create_order(account.tokens, cart_id, product_id, fee,
                                               f"loadgen:{self.run_id}")
            order_id = int(order["orderId"])
            self.publisher.publish(build_event(order_id, account.user_id, product_id, fee, shipping,
                                               account.country, "loadgen", account_created), scenario)
            self.metrics.orders.labels(scenario, "ok").inc()
            if pay:
                self.platform.create_payment(account.tokens, order_id, account.user_id)
                self.metrics.payments.labels(scenario).inc()
        except (ApiError, KeyError, ValueError, RuntimeError) as e:
            self.metrics.orders.labels(scenario, "error").inc()
            log.warning("%s order failed: %s", scenario, e)

    def run_scenario(self, scenario):
        from common.api import ApiError

        self.metrics.in_flight.inc()
        try:
            if scenario == "high_value_new_account":
                account, created = self.fresh_account()
                self.place(scenario, account,
                           lambda p: high_value_fee(p, self.cfg.high_value_multiplier, self.cfg.high_value_min_fee),
                           account.country, True, account_created=created)
                return
            account = self.pool_account()
            normal_fee = lambda p: self.rand(basket, p)  # noqa: E731
            if scenario == "rapid_repeat":
                gap = self.cfg.repeat_window / max(1, self.cfg.repeat_count)
                for _ in range(self.cfg.repeat_count):
                    if self.stop.is_set():
                        break
                    self.place(scenario, account, normal_fee, account.country, True)
                    time.sleep(gap)
            elif scenario == "geo_mismatch":
                shipping = self.rand(mismatched_country, self.cfg.countries, account.country)
                self.place(scenario, account, normal_fee, shipping, True)
            else:
                pay = self.rand(lambda rng: rng.random() < self.cfg.pay_ratio)
                self.place(scenario, account, normal_fee, account.country, pay)
        except (ApiError, RuntimeError) as e:
            self.metrics.orders.labels(scenario, "error").inc()
            log.warning("%s scenario failed before ordering: %s", scenario, e)
        finally:
            self.metrics.in_flight.dec()

    def run(self):
        cfg = self.cfg
        log.info("loadgen run=%s rate=%.2f/s fraud=%.3f mix=%s users=%d seed=%d",
                 self.run_id, cfg.rate, cfg.fraud_ratio, cfg.fraud_mix, cfg.users, cfg.seed)
        slots = threading.BoundedSemaphore(cfg.workers * 4)
        deadline = time.monotonic() + cfg.duration if cfg.duration else None
        next_at = time.monotonic()
        with ThreadPoolExecutor(max_workers=cfg.workers) as pool:
            while not self.stop.is_set():
                next_at += self.rand(next_gap, cfg.rate)
                if deadline and next_at > deadline:
                    break
                if self.stop.wait(max(0.0, next_at - time.monotonic())):
                    break
                scenario = self.rand(choose_scenario, cfg.fraud_ratio, cfg.fraud_mix)
                self.metrics.arrivals.labels(scenario).inc()
                # A bounded backlog keeps the offered load honest: when the platform is
                # slower than the arrival rate, arrivals are dropped and counted.
                if not slots.acquire(blocking=False):
                    self.metrics.dropped.inc()
                    continue
                pool.submit(self.run_scenario, scenario).add_done_callback(lambda _: slots.release())
            self.stop.set()
        self.publisher.flush()
        log.info("loadgen stopped")


def run_live():
    from common.accounts import Accounts, user_password
    from common.api import Platform
    from common.order_context import OrderContextPublisher

    setup_logging()
    cfg = Config.from_env()
    metrics = Metrics(env("METRICS_PORT", 9000, int))
    platform = Platform(env("GATEWAY_URL"), env("KEYCLOAK_URL"), env("KEYCLOAK_REALM", "ecommerce"),
                        max_rps=env("MAX_RPS", 15.0, float), on_response=metrics.on_response)
    accounts = Accounts(platform, env("PUBLIC_CLIENT_ID", "ecommerce-client"),
                        user_password(env("DATA_TOOLS_USER_PASSWORD")))
    publisher = OrderContextPublisher(env("KAFKA_BOOTSTRAP", "kafka-dc1-kafka-bootstrap:9092"),
                                      env("ORDER_CONTEXT_TOPIC", "order-context"),
                                      enabled=env_bool("ORDER_CONTEXT_ENABLED", True))
    generator = LoadGenerator(cfg, platform, accounts, publisher, metrics)
    signal.signal(signal.SIGTERM, lambda *_: generator.stop.set())
    signal.signal(signal.SIGINT, lambda *_: generator.stop.set())
    generator.run()


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command")
    sub.add_parser("run", help="generate traffic against the platform (default)")
    sim = sub.add_parser("simulate", help="print arrival/scenario statistics offline")
    sim.add_argument("--seconds", type=float, default=3600)
    args = parser.parse_args()
    if args.command == "simulate":
        simulate(Config.from_env(), args.seconds)
    else:
        run_live()


if __name__ == "__main__":
    main()
