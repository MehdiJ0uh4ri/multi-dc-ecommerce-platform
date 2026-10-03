package local.platform.fraud;

import java.time.Duration;
import java.util.function.LongSupplier;
import local.platform.fraud.Model.Alert;
import local.platform.fraud.Model.Order;
import local.platform.fraud.Model.OrderContext;
import local.platform.fraud.Model.PaidOrder;
import local.platform.fraud.Model.Payment;
import local.platform.fraud.Model.UserState;
import org.apache.kafka.common.serialization.Serde;
import org.apache.kafka.common.serialization.Serdes;
import org.apache.kafka.common.utils.Bytes;
import org.apache.kafka.streams.StreamsBuilder;
import org.apache.kafka.streams.Topology;
import org.apache.kafka.streams.kstream.Consumed;
import org.apache.kafka.streams.kstream.GlobalKTable;
import org.apache.kafka.streams.kstream.JoinWindows;
import org.apache.kafka.streams.kstream.KStream;
import org.apache.kafka.streams.kstream.Materialized;
import org.apache.kafka.streams.kstream.Named;
import org.apache.kafka.streams.kstream.Produced;
import org.apache.kafka.streams.kstream.Repartitioned;
import org.apache.kafka.streams.kstream.StreamJoined;
import org.apache.kafka.streams.processor.api.FixedKeyProcessor;
import org.apache.kafka.streams.processor.api.FixedKeyProcessorContext;
import org.apache.kafka.streams.processor.api.FixedKeyRecord;
import org.apache.kafka.streams.state.KeyValueStore;
import org.apache.kafka.streams.state.Stores;

/**
 * SUCCESSFUL (payments, no key) ─ rekey orderId ─┐
 *                                               ├─ windowed join ─► paid orders ─┬─ ⨝ order-context (windowed) ─► GEO_MISMATCH
 * dborder.public.orders (Debezium, op c) ───────┘                                └─ ⨝ product prices (GlobalKTable)
 *                                                                                    ─ rekey userId ─► UserRiskProcessor ─► VELOCITY, AMOUNT_ANOMALY
 * All alerts ─► fraud-alerts (key userId).
 */
public final class FraudTopology {
    private FraudTopology() {
    }

    public static Topology build(Config config, LongSupplier clock, Metrics metrics) {
        Serde<String> text = Serdes.String();
        Serde<Payment> paymentSerde = Json.serde(Payment.class);
        Serde<Order> orderSerde = Json.serde(Order.class);
        Serde<PaidOrder> paidSerde = Json.serde(PaidOrder.class);
        Serde<OrderContext> contextSerde = Json.serde(OrderContext.class);
        Serde<Alert> alertSerde = Json.serde(Alert.class);
        // Late records (e.g. MirrorMaker 2 catching up after a partition) still join.
        JoinWindows window = JoinWindows.ofTimeDifferenceAndGrace(config.joinWindow(), Duration.ofMinutes(5));

        StreamsBuilder builder = new StreamsBuilder();

        KStream<String, Payment> payments = builder
                .stream(config.paymentsTopic(), Consumed.with(text, text).withName("payments-source"))
                .processValues(RecordTimestamp::new, Named.as("payments-timestamp"))
                .filter((k, p) -> keep(p != null && Boolean.TRUE.equals(p.isPayed()), metrics, "payments"),
                        Named.as("payments-paid"))
                .selectKey((k, p) -> Long.toString(p.orderId()), Named.as("payments-by-order"));

        KStream<String, Order> orders = builder
                .stream(config.ordersTopic(), Consumed.with(text, text).withName("orders-source"))
                .mapValues(Json::orderCreated, Named.as("orders-parse"))
                .filter((k, o) -> o != null, Named.as("orders-created"))
                .selectKey((k, o) -> Long.toString(o.orderId()), Named.as("orders-by-id"));

        KStream<String, PaidOrder> paid = payments.join(orders, PaidOrder::of, window,
                StreamJoined.with(text, paymentSerde, orderSerde).withName("payment-order"));

        KStream<String, OrderContext> contexts = builder
                .stream(config.contextTopic(), Consumed.with(text, text).withName("context-source"))
                .mapValues(Json::orderContext, Named.as("context-parse"))
                .filter((k, c) -> keep(c != null, metrics, "order-context"), Named.as("context-valid"))
                .selectKey((k, c) -> Long.toString(c.orderId()), Named.as("context-by-order"));

        KStream<String, Alert> geo = paid
                .join(contexts, (order, ctx) -> Rules.geoMismatch(order, ctx, clock.getAsLong()), window,
                        StreamJoined.with(text, paidSerde, contextSerde).withName("paid-context"))
                .filter((k, alert) -> alert != null, Named.as("geo-mismatch"))
                .selectKey((k, alert) -> Long.toString(alert.userId()), Named.as("geo-by-user"));

        GlobalKTable<String, Double> prices = builder.globalTable(config.productsTopic(),
                Consumed.with(ProductSerdes.key(), ProductSerdes.price()).withName("products-source"),
                Materialized.<String, Double, KeyValueStore<Bytes, byte[]>>as("product-prices")
                        .withKeySerde(ProductSerdes.key()).withValueSerde(ProductSerdes.price()));

        builder.addStateStore(Stores.keyValueStoreBuilder(
                Stores.persistentKeyValueStore(UserRiskProcessor.STORE), text, Json.serde(UserState.class)));

        KStream<String, Alert> userRisk = paid
                .leftJoin(prices, (k, order) -> order.productId() == null ? null : Long.toString(order.productId()),
                        (order, price) -> order.withUnitPrice(price), Named.as("paid-price"))
                .selectKey((k, order) -> Long.toString(order.userId()), Named.as("paid-by-user"))
                .repartition(Repartitioned.with(text, paidSerde).withName("paid-by-user"))
                .process(() -> new UserRiskProcessor(config, clock), Named.as("user-risk"), UserRiskProcessor.STORE);

        userRisk.merge(geo, Named.as("alerts"))
                .peek((k, alert) -> metrics.inc("fraud_alerts_total", "rule", alert.rule()), Named.as("alerts-count"))
                .to(config.alertsTopic(), Produced.with(text, alertSerde).withName("alerts-sink"));

        return builder.build();
    }

    private static boolean keep(boolean valid, Metrics metrics, String input) {
        if (!valid) {
            metrics.inc("fraud_detector_skipped_total", "input", input);
        }
        return valid;
    }

    /** Parses a payment and stamps it with its Kafka record timestamp (alert latency baseline). */
    static final class RecordTimestamp implements FixedKeyProcessor<String, String, Payment> {
        private FixedKeyProcessorContext<String, Payment> context;

        @Override
        public void init(FixedKeyProcessorContext<String, Payment> context) {
            this.context = context;
        }

        @Override
        public void process(FixedKeyRecord<String, String> record) {
            Payment payment = Json.payment(record.value());
            context.forward(record.withValue(payment == null ? null : payment.withTs(record.timestamp())));
        }
    }
}
