package local.platform.fraud;

import java.time.Duration;
import java.util.Map;

/** Environment settings, with the defaults used in dc2-analytics (helm-values/dc2-analytics/fraud-detection.yaml). */
public record Config(
        String bootstrap,
        String applicationId,
        String paymentsTopic,
        String ordersTopic,
        String productsTopic,
        String contextTopic,
        String alertsTopic,
        Duration joinWindow,
        int velocityCount,
        Duration velocityWindow,
        double amountQuantityFactor,
        int lowHistoryPayments,
        String stateDir,
        int metricsPort) {

    public static Config fromEnv(Map<String, String> env) {
        return new Config(
                get(env, "KAFKA_BOOTSTRAP", "kafka-dc2-kafka-bootstrap:9092"),
                get(env, "APPLICATION_ID", "fraud-detector"),
                get(env, "TOPIC_PAYMENTS", "SUCCESSFUL"),
                get(env, "TOPIC_ORDERS", "dborder.public.orders"),
                get(env, "TOPIC_PRODUCTS", "dbproduct.public.product"),
                get(env, "TOPIC_ORDER_CONTEXT", "order-context"),
                get(env, "TOPIC_ALERTS", "fraud-alerts"),
                Duration.ofSeconds(Long.parseLong(get(env, "JOIN_WINDOW_S", "600"))),
                Integer.parseInt(get(env, "VELOCITY_COUNT", "5")),
                Duration.ofSeconds(Long.parseLong(get(env, "VELOCITY_WINDOW_S", "30"))),
                Double.parseDouble(get(env, "AMOUNT_QTY_FACTOR", "10")),
                Integer.parseInt(get(env, "LOW_HISTORY_PAYMENTS", "3")),
                get(env, "STATE_DIR", "/tmp/kafka-streams"),
                Integer.parseInt(get(env, "METRICS_PORT", "9000")));
    }

    static String get(Map<String, String> env, String name, String fallback) {
        String value = env.get(name);
        return value == null || value.isBlank() ? fallback : value;
    }
}
