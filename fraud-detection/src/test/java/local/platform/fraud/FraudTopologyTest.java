package local.platform.fraud;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.time.Instant;
import java.util.List;
import java.util.Map;
import java.util.Properties;
import local.platform.fraud.Model.Alert;
import org.apache.kafka.common.serialization.StringDeserializer;
import org.apache.kafka.common.serialization.StringSerializer;
import org.apache.kafka.streams.StreamsConfig;
import org.apache.kafka.streams.TestInputTopic;
import org.apache.kafka.streams.TestOutputTopic;
import org.apache.kafka.streams.TopologyTestDriver;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

/** The real topology on TopologyTestDriver, with messages shaped like the live topics. */
class FraudTopologyTest {
    static final Instant T0 = Instant.parse("2026-09-18T10:00:00Z");

    TopologyTestDriver driver;
    TestInputTopic<String, String> payments;
    TestInputTopic<String, String> orders;
    TestInputTopic<String, String> products;
    TestInputTopic<String, String> contexts;
    TestOutputTopic<String, String> alerts;
    Metrics metrics = new Metrics();

    @BeforeEach
    void setUp() throws Exception {
        Config config = Config.fromEnv(Map.of("STATE_DIR", Files.createTempDirectory("fraud-test").toString()));
        Properties props = new Properties();
        props.put(StreamsConfig.APPLICATION_ID_CONFIG, "fraud-test");
        props.put(StreamsConfig.BOOTSTRAP_SERVERS_CONFIG, "unused:9092");
        props.put(StreamsConfig.STATE_DIR_CONFIG, config.stateDir());
        driver = new TopologyTestDriver(FraudTopology.build(config, () -> 42L, metrics), props);
        StringSerializer s = new StringSerializer();
        payments = driver.createInputTopic("SUCCESSFUL", s, s);
        orders = driver.createInputTopic("dborder.public.orders", s, s);
        products = driver.createInputTopic("dbproduct.public.product", s, s);
        contexts = driver.createInputTopic("order-context", s, s);
        alerts = driver.createOutputTopic("fraud-alerts", new StringDeserializer(), new StringDeserializer());
        product(1, 10.0);
        product(2, 1000.0);
    }

    @AfterEach
    void tearDown() {
        driver.close();
    }

    // --- messages as they appear on the mirrored topics ---------------------------
    void product(long id, double price) {
        // Debezium key after ReplaceField (ADR-021), envelope with decimal.handling.mode=double.
        products.pipeInput("{\"id\":" + id + "}", "{\"before\":null,\"after\":{\"product_id\":" + id
                + ",\"product_title\":\"p\",\"price_unit\":" + price + "},\"op\":\"c\",\"ts_ms\":1}", T0);
    }

    void order(long orderId, long productId, double fee, long offsetSeconds) {
        orders.pipeInput("{\"order_id\":" + orderId + "}", "{\"before\":null,\"after\":{\"order_id\":" + orderId
                + ",\"order_date\":1789000000000000,\"order_desc\":\"loadgen:x\",\"order_fee\":" + fee
                + ",\"product_id\":" + productId + ",\"cart_id\":3},\"source\":{\"table\":\"orders\"},\"op\":\"c\"}",
                T0.plusSeconds(offsetSeconds));
    }

    void pay(long orderId, long userId, long offsetSeconds) {
        // payment-service sends without a key (EventProducer.send(topic, message)).
        payments.pipeInput(null, "{\"paymentId\":" + orderId + ",\"isPayed\":true,\"paymentStatus\":\"COMPLETED\","
                + "\"orderId\":" + orderId + ",\"userId\":" + userId + "}", T0.plusSeconds(offsetSeconds));
    }

    void context(long orderId, long userId, String shipping, String billing, long offsetSeconds) {
        contexts.pipeInput(Long.toString(orderId), "{\"orderId\":" + orderId + ",\"userId\":" + userId
                + ",\"productId\":1,\"orderFee\":20.0,\"shippingCountry\":\"" + shipping + "\",\"billingCountry\":\""
                + billing + "\",\"accountCreated\":false,\"source\":\"loadgen\",\"ts\":\"x\"}",
                T0.plusSeconds(offsetSeconds));
    }

    List<Alert> readAlerts() {
        return alerts.readValuesToList().stream().map(v -> {
            try {
                return Json.MAPPER.readValue(v, Alert.class);
            } catch (Exception e) {
                throw new AssertionError(e);
            }
        }).toList();
    }

    // --- rules ------------------------------------------------------------------------
    @Test
    void normalOrderRaisesNothing() {
        order(100, 1, 30.0, 0);
        context(100, 7, "FR", "FR", 0);
        pay(100, 7, 1);
        assertEquals(List.of(), readAlerts());
    }

    @Test
    void geoMismatchOnPaidOrder() {
        order(101, 1, 20.0, 0);
        context(101, 7, "DE", "FR", 0);
        pay(101, 7, 2);
        List<Alert> out = readAlerts();
        assertEquals(1, out.size());
        Alert a = out.get(0);
        assertEquals(Rules.GEO_MISMATCH, a.rule());
        assertEquals("GEO_MISMATCH-101", a.alertId());
        assertEquals("DE", a.shippingCountry());
        assertEquals("FR", a.billingCountry());
        assertEquals(T0.plusSeconds(2).toEpochMilli(), a.paymentTs());
        assertEquals(42L, a.detectedAt());
    }

    @Test
    void unpaidMismatchRaisesNothing() {
        order(102, 1, 20.0, 0);
        context(102, 7, "DE", "FR", 0);
        assertEquals(List.of(), readAlerts());
    }

    @Test
    void amountAnomalyForNewAccountIsHigh() {
        pay(200, 8, 0);           // payment first: the orders CDC can lag behind
        order(200, 1, 2000.0, 3); // 200 x the unit price of 10
        List<Alert> out = readAlerts();
        assertEquals(1, out.size());
        Alert a = out.get(0);
        assertEquals(Rules.AMOUNT_ANOMALY, a.rule());
        assertEquals("high", a.severity());
        assertEquals(0L, a.userPriorPayments());
        assertEquals(200.0, a.quantityRatio());
    }

    @Test
    void expensiveProductIsNotAnAnomaly() {
        order(201, 2, 3000.0, 0); // 3 x 1000
        pay(201, 8, 1);
        assertEquals(List.of(), readAlerts());
    }

    @Test
    void amountAnomalyWithHistoryIsMedium() {
        for (int i = 0; i < 3; i++) {
            order(300 + i, 1, 10.0, i * 100L);
            pay(300 + i, 9, i * 100L + 1);
        }
        order(310, 1, 150.0, 1000);
        pay(310, 9, 1001);
        List<Alert> out = readAlerts();
        assertEquals(1, out.size());
        assertEquals("medium", out.get(0).severity());
        assertEquals(3L, out.get(0).userPriorPayments());
    }

    @Test
    void velocityRaisesOneAlertPerBurst() {
        // rapid_repeat: 6 paid orders in 20 s; the threshold is 5 in 30 s.
        for (int i = 0; i < 6; i++) {
            order(400 + i, 1, 10.0, i * 4L);
            pay(400 + i, 11, i * 4L + 1);
        }
        List<Alert> out = readAlerts();
        assertEquals(1, out.size());
        Alert a = out.get(0);
        assertEquals(Rules.VELOCITY, a.rule());
        assertEquals(5, a.paymentCount());
        assertEquals(List.of(400L, 401L, 402L, 403L, 404L), a.orderIds());

        // A second burst after the quiet period raises a new alert.
        for (int i = 0; i < 5; i++) {
            order(500 + i, 1, 10.0, 100 + i * 2L);
            pay(500 + i, 11, 100 + i * 2L + 1);
        }
        assertEquals(1, readAlerts().size());
    }

    @Test
    void slowOrdersAreNotVelocity() {
        for (int i = 0; i < 6; i++) {
            order(600 + i, 1, 10.0, i * 10L);
            pay(600 + i, 12, i * 10L + 1); // 6 orders in 51 s: never 5 within 30 s
        }
        assertEquals(List.of(), readAlerts());
    }

    @Test
    void duplicatePaymentIsCountedOnce() {
        for (int i = 0; i < 4; i++) {
            order(700 + i, 1, 10.0, i);
            pay(700 + i, 13, i);
            pay(700 + i, 13, i); // MirrorMaker 2 redelivery
        }
        assertEquals(List.of(), readAlerts());
    }

    @Test
    void foreignMessagesAreSkipped() {
        payments.pipeInput(null, "{\"verify\":\"phase4-123\"}", T0);   // verify-phase4 probe
        payments.pipeInput(null, "not json", T0);
        orders.pipeInput("{\"order_id\":1}", "{\"op\":\"u\",\"after\":{\"order_id\":1,\"order_fee\":1.0}}", T0);
        orders.pipeInput("{\"order_id\":1}", null, T0);                 // Debezium tombstone
        assertEquals(List.of(), readAlerts());
        assertTrue(metrics.render().contains("fraud_detector_skipped_total{input=\"payments\"} 2.0"));
    }

    @Test
    void paymentOutsideJoinWindowDoesNotJoin() {
        order(800, 1, 5000.0, 0);
        pay(800, 14, 3600); // an hour later: beyond the 10 min window + 5 min grace
        assertEquals(List.of(), readAlerts());
    }

    // --- serdes / formatting ------------------------------------------------------------
    @Test
    void productSerdesRoundTripBothForms() {
        var key = ProductSerdes.key();
        byte[] raw = "{\"id\":17}".getBytes(StandardCharsets.UTF_8);
        assertEquals("17", key.deserializer().deserialize("t", raw));
        assertEquals("{\"id\":17}", new String(key.serializer().serialize("t", "17"), StandardCharsets.UTF_8));

        var price = ProductSerdes.price();
        byte[] envelope = "{\"after\":{\"price_unit\":9.99},\"op\":\"u\"}".getBytes(StandardCharsets.UTF_8);
        assertEquals(9.99, price.deserializer().deserialize("t", envelope));
        assertEquals(9.99, price.deserializer().deserialize("t", price.serializer().serialize("t", 9.99)));
        assertNull(price.deserializer().deserialize("t", "{\"after\":null,\"op\":\"d\"}".getBytes()));
        assertNull(price.deserializer().deserialize("t", null));
    }

    @Test
    void mailNamesTheOrder() {
        Alert a = Rules.geoMismatch(new Model.PaidOrder(55, 7, 1L, 20.0, 10.0, 1000),
                new Model.OrderContext(55L, 7L, "DE", "FR", false), 3000);
        assertEquals("[FRAUD MEDIUM] GEO_MISMATCH user 7 order 55", AlertMail.subject(a));
        String body = AlertMail.body(a, 2000);
        assertTrue(body.contains("shipping country:    DE"), body);
        assertTrue(body.contains("payment -> mail:     2.0 s"), body);
        assertEquals(2000L, AlertIndexer.document(a, 3000).get("latencyMs").asLong());
    }

    @Test
    void latencyHistogramBuckets() {
        Metrics m = new Metrics();
        m.observeLatency("VELOCITY", 12.5);
        String text = m.render();
        assertTrue(text.contains("fraud_alert_latency_seconds_bucket{rule=\"VELOCITY\",le=\"10\"}") == false);
        assertTrue(text.contains("fraud_alert_latency_seconds_bucket{rule=\"VELOCITY\",le=\"15\"} 1.0"), text);
        assertTrue(text.contains("fraud_alert_latency_seconds_bucket{rule=\"VELOCITY\",le=\"+Inf\"} 1.0"), text);
    }
}
