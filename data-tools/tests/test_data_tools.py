"""Offline tests: `make data-tools-test` (runs inside the built image, no cluster needed)."""
import csv
import gzip
import json
import random
import re
import sys
import tempfile
import time
import unittest
from argparse import Namespace
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "seed"))
sys.path.insert(0, str(ROOT / "loadgen"))

import loadgen  # noqa: E402
import seed_orders  # noqa: E402
import seed_products  # noqa: E402
from common import phone_number  # noqa: E402
from common.accounts import Accounts, user_password  # noqa: E402
from common.api import ApiError, RateLimiter  # noqa: E402

# Validation rules copied from auth-service RegisterRequest (app/auth-service/.../RegisterRequest.java).
PASSWORD = re.compile(r"^(?=.*[a-z])(?=.*[A-Z])(?=.*\d)[a-zA-Z\d]{8,}$")
PHONE = re.compile(r"^\+84[0-9]{9,10}$|^0[0-9]{9,10}$")
EMAIL = re.compile(r"[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}")


def assert_register_request(case, profile):
    case.assertGreaterEqual(len(profile["fullName"]), 6)
    case.assertLessEqual(len(profile["fullName"]), 50)
    case.assertGreaterEqual(len(profile["username"]), 6)
    case.assertTrue(EMAIL.fullmatch(profile["email"]), profile["email"])
    case.assertTrue(PHONE.fullmatch(profile["phone"]), profile["phone"])
    case.assertTrue(profile["gender"])


class LoadgenTest(unittest.TestCase):
    def cfg(self, **overrides):
        base = dict(rate=5.0, fraud_ratio=0.05,
                    fraud_mix={"rapid_repeat": 1, "geo_mismatch": 1, "high_value_new_account": 1},
                    users=50, pay_ratio=0.9, workers=4, duration=0, countries={"FR": 3, "DE": 1},
                    repeat_count=6, repeat_window=20, high_value_multiplier=20, high_value_min_fee=2000, seed=7)
        base.update(overrides)
        return loadgen.Config(**base)

    def test_poisson_rate_and_fraud_share(self):
        counts = loadgen.simulate(self.cfg(), 20000)
        total = sum(counts.values())
        self.assertAlmostEqual(total / 20000, 5.0, delta=0.1)
        fraud = 1 - counts[loadgen.NORMAL] / total
        self.assertAlmostEqual(fraud, 0.05, delta=0.005)
        for pattern in loadgen.FRAUD_PATTERNS:
            self.assertAlmostEqual(counts[pattern] / total, 0.05 / 3, delta=0.004)

    def test_exponential_gaps(self):
        rng = random.Random(1)
        gaps = [loadgen.next_gap(rng, 2.0) for _ in range(50000)]
        mean = sum(gaps) / len(gaps)
        self.assertAlmostEqual(mean, 0.5, delta=0.01)
        # Exponential: P(gap > mean) = e^-1.
        self.assertAlmostEqual(sum(g > mean for g in gaps) / len(gaps), 0.3679, delta=0.01)

    def test_mix_weights_and_validation(self):
        self.assertEqual(loadgen.parse_weights("geo_mismatch=3", loadgen.FRAUD_PATTERNS), {"geo_mismatch": 3.0})
        with self.assertRaises(ValueError):
            loadgen.parse_weights("card_testing=1", loadgen.FRAUD_PATTERNS)
        with self.assertRaises(ValueError):
            loadgen.parse_weights("geo_mismatch=0", loadgen.FRAUD_PATTERNS)
        rng = random.Random(3)
        picks = {loadgen.choose_scenario(rng, 1.0, {"geo_mismatch": 1}) for _ in range(100)}
        self.assertEqual(picks, {"geo_mismatch"})

    def test_geo_mismatch_never_matches_home(self):
        rng = random.Random(5)
        countries = {"FR": 40, "DE": 20, "ES": 15}
        for _ in range(1000):
            self.assertNotEqual(loadgen.mismatched_country(rng, countries, "FR"), "FR")

    def test_high_value_fee(self):
        self.assertEqual(loadgen.high_value_fee(10.0, 20, 2000), 2000)
        self.assertEqual(loadgen.high_value_fee(500.0, 20, 2000), 10000)

    def test_generated_profiles_pass_register_request(self):
        assert_register_request(self, {"fullName": "Loadgen Shopper 00001", "username": "lgpool00001",
                                       "email": "lgpool00001@loadgen.example.com", "gender": "MALE",
                                       "phone": phone_number("09", 1)})
        assert_register_request(self, {"fullName": "Loadgen Newcomer 000001",
                                       "username": "lgnewabc123000001",
                                       "email": "lgnewabc123000001@loadgen.example.com", "gender": "MALE",
                                       "phone": phone_number("07", 99999999)})


class SeedOrdersTest(unittest.TestCase):
    def write_olist(self, directory):
        rows = {
            "olist_orders_dataset.csv": [
                ["order_id", "customer_id", "order_status", "order_purchase_timestamp"],
                ["o1", "c1", "delivered", "2017-11-01 10:00:00"],
                ["o2", "c2", "delivered", "2017-11-01 10:30:00"],
                ["o3", "c1", "canceled", "2017-11-01 11:00:00"],
                ["o0", "c2", "delivered", "2017-10-31 23:59:59"],
                ["o4", "c1", "shipped", "2017-11-02 10:00:00"],
            ],
            "olist_order_items_dataset.csv": [
                ["order_id", "order_item_id", "product_id", "price", "freight_value"],
                ["o1", "1", "pA", "10.00", "2.50"], ["o1", "2", "pB", "5.00", "1.00"],
                ["o2", "1", "pB", "99.90", "10.00"], ["o4", "1", "pA", "1.00", "0.00"],
            ],
            "olist_customers_dataset.csv": [
                ["customer_id", "customer_unique_id", "customer_state"],
                ["c1", "0123456789abcdef0123456789abcdef", "SP"],
                ["c2", "fedcba9876543210fedcba9876543210", "RJ"],
            ],
            "olist_order_payments_dataset.csv": [
                ["order_id", "payment_type", "payment_value"],
                ["o1", "credit_card", "10.00"], ["o1", "voucher", "8.50"], ["o2", "boleto", "109.90"],
            ],
        }
        for name, table in rows.items():
            with open(Path(directory) / name, "w", newline="") as f:
                csv.writer(f).writerows(table)

    def test_prepare_and_schedule(self):
        with tempfile.TemporaryDirectory() as d:
            self.write_olist(d)
            out = Path(d) / "replay.jsonl.gz"
            seed_orders.prepare(Namespace(input=d, output=str(out), start="2017-11-01", limit=10))
            records = seed_orders.load_replay(out, 0)
            self.assertEqual([r["o"] for r in records], ["o1", "o2", "o4"])
            self.assertEqual(records[0]["f"], 18.5)
            self.assertEqual(records[0]["pv"], 18.5)
            self.assertEqual(records[2]["pv"], 0)
            self.assertEqual(records[0]["ip"], 10.0)
            self.assertEqual(seed_orders.schedule(records, 60), [0.0, 30.0, 1440.0])
            self.assertEqual(len(seed_orders.load_replay(out, 2)), 2)
            json.loads(gzip.decompress(out.read_bytes()).splitlines()[0])

    def test_closest_product(self):
        catalogue = [(5.0, 1), (9.99, 2), (10.01, 3), (500.0, 4)]
        self.assertEqual(seed_orders.closest_product(catalogue, 1.0, 0), 1)
        self.assertEqual(seed_orders.closest_product(catalogue, 9.98, 0), 2)
        self.assertEqual(seed_orders.closest_product(catalogue, 9000.0, 0), 4)
        self.assertIn(seed_orders.closest_product(catalogue, 10.0, 7), (2, 3))
        self.assertEqual(seed_orders.closest_product(catalogue, 10.0, 7),
                         seed_orders.closest_product(catalogue, 10.0, 7))

    def test_shopper_profiles(self):
        a = seed_orders.shopper_profile("0123456789abcdef0123456789abcdef")
        self.assertEqual(a, seed_orders.shopper_profile("0123456789abcdef0123456789abcdef"))
        assert_register_request(self, a)
        retry = seed_orders.shopper_profile("0123456789abcdef0123456789abcdef", attempt=1)
        self.assertEqual(retry["username"], a["username"])
        self.assertNotEqual(retry["phone"], a["phone"])


class SeedProductsTest(unittest.TestCase):
    def test_mapping(self):
        item = {"title": "Essence Mascara", "category": "home-decoration", "price": 9.99, "stock": 99,
                "sku": "BEA-ESS-001", "thumbnail": "https://cdn.example/x.webp"}
        self.assertEqual(seed_products.category_title(item["category"]), "Home Decoration")
        self.assertEqual(seed_products.to_product(item, 4), {
            "productTitle": "Essence Mascara", "imageUrl": "https://cdn.example/x.webp", "sku": "BEA-ESS-001",
            "priceUnit": 9.99, "quantity": 99, "category": {"categoryId": 4}})


class FakePlatform:
    """Existing user 'taken' has another password; any other signup conflicts on phone once."""

    def __init__(self):
        self.users = {}
        self.phones = {"0900000001"}

    def signup(self, profile):
        if profile["username"] in self.users or profile["phone"] in self.phones:
            return False
        self.users[profile["username"]] = len(self.users) + 1
        self.phones.add(profile["phone"])
        return True

    def password_grant(self, client_id, username, password):
        return username

    def current_user_id(self, username):
        if username not in self.users:
            raise ApiError("POST", "/token", 401, "invalid_grant")
        return self.users[username]


class AccountsTest(unittest.TestCase):
    def test_password_rule(self):
        for base in ("abcdefgh", "ABCDEFGH", "12345678", "x" * 60):
            self.assertTrue(PASSWORD.fullmatch(user_password(base)))
            self.assertLessEqual(len(user_password(base)), 50)
        with self.assertRaises(ValueError):
            user_password("has-dash")

    def test_retry_on_conflicting_phone(self):
        accounts = Accounts(FakePlatform(), "ecommerce-client", "pw")
        make = lambda attempt: {"username": "lgpool00001", "phone": phone_number("09", 1 + attempt)}  # noqa: E731
        account, created = accounts.ensure(make)
        self.assertTrue(created)
        self.assertEqual(account.user_id, 1)
        again, created = accounts.ensure(make)
        self.assertIs(again, account)
        self.assertFalse(created)


class RateLimiterTest(unittest.TestCase):
    def test_rate(self):
        limiter = RateLimiter(50)
        started = time.monotonic()
        for _ in range(100):
            limiter.acquire()
        # First 50 come from the initial 1-second burst, the next 50 take ~1 s.
        self.assertAlmostEqual(time.monotonic() - started, 1.0, delta=0.25)


if __name__ == "__main__":
    unittest.main()
