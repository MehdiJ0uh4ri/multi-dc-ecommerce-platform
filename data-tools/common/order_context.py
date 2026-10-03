"""Platform-owned `order-context` events (ADR-030).

The upstream app stores no geography: orders, payments and shipments have no country or
address (docs/upstream-app-findings.md #10). A checkout front end would know the shipping
and billing countries, so the data tools publish them next to each order they place.

Topic `order-context` on kafka-dc1, key = orderId, JSON value:

    {"orderId": 123, "userId": 45, "productId": 7, "orderFee": 59.97,
     "shippingCountry": "FR", "billingCountry": "FR", "accountCreated": false,
     "source": "loadgen", "ts": "2026-09-18T10:00:00.123Z"}

MirrorMaker 2 copies it to DC2, where fraud detection joins it with the orders CDC stream
and the payment topic "SUCCESSFUL" (Phase 5a).

The generator's intent (normal or a fraud pattern) travels only in the Kafka header
`scenario`, as ground truth for measuring detection. Detectors must not read it.
"""
import json
import logging
from datetime import datetime, timezone

log = logging.getLogger(__name__)


def utc_now():
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def build_event(order_id, user_id, product_id, fee, shipping, billing, source, account_created=False, ts=None):
    return {
        "orderId": order_id,
        "userId": user_id,
        "productId": product_id,
        "orderFee": round(fee, 2),
        "shippingCountry": shipping,
        "billingCountry": billing,
        "accountCreated": account_created,
        "source": source,
        "ts": ts or utc_now(),
    }


class OrderContextPublisher:
    def __init__(self, bootstrap, topic, enabled=True):
        self.topic = topic
        self.producer = None
        if enabled:
            from confluent_kafka import Producer

            self.producer = Producer({
                "bootstrap.servers": bootstrap,
                "client.id": "data-tools",
                "acks": "all",
                "enable.idempotence": True,
                "linger.ms": 50,
            })

    def publish(self, event, scenario):
        if self.producer is None:
            return
        self.producer.produce(
            self.topic,
            key=str(event["orderId"]).encode(),
            value=json.dumps(event, separators=(",", ":")).encode(),
            headers=[("scenario", scenario.encode())],
            on_delivery=self._delivered,
        )
        self.producer.poll(0)

    @staticmethod
    def _delivered(err, msg):
        if err is not None:
            log.error("order-context delivery failed: %s", err)

    def flush(self, timeout=15):
        if self.producer is not None:
            left = self.producer.flush(timeout)
            if left:
                log.error("%d order-context events not delivered", left)
