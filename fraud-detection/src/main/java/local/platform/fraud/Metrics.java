package local.platform.fraud;

import com.sun.net.httpserver.HttpServer;
import java.io.IOException;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.util.Map;
import java.util.TreeMap;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.DoubleAdder;
import java.util.function.BooleanSupplier;

/**
 * Minimal Prometheus text exposition plus /health, on METRICS_PORT (9000, already open to
 * the monitoring namespace by allow-monitoring@dc2). Counters, and one histogram for alert
 * latency.
 */
public final class Metrics {
    static final double[] LATENCY_BUCKETS = {1, 2, 5, 10, 15, 20, 30, 60, 120};

    private final Map<String, DoubleAdder> samples = new ConcurrentHashMap<>();

    public void inc(String name, String label, String value) {
        add(name + "{" + label + "=\"" + value + "\"}", 1);
    }

    public void inc(String name) {
        add(name, 1);
    }

    /** Histogram fraud_alert_latency_seconds{rule}: payment record time -> mail sent. */
    public void observeLatency(String rule, double seconds) {
        String labels = "rule=\"" + rule + "\"";
        for (double bucket : LATENCY_BUCKETS) {
            if (seconds <= bucket) {
                add("fraud_alert_latency_seconds_bucket{" + labels + ",le=\"" + fmt(bucket) + "\"}", 1);
            }
        }
        add("fraud_alert_latency_seconds_bucket{" + labels + ",le=\"+Inf\"}", 1);
        add("fraud_alert_latency_seconds_sum{" + labels + "}", seconds);
        add("fraud_alert_latency_seconds_count{" + labels + "}", 1);
    }

    private void add(String sample, double amount) {
        samples.computeIfAbsent(sample, k -> new DoubleAdder()).add(amount);
    }

    public String render() {
        StringBuilder out = new StringBuilder();
        new TreeMap<>(samples).forEach((sample, value) -> out.append(sample).append(' ').append(value.sum()).append('\n'));
        return out.toString();
    }

    private static String fmt(double value) {
        return value == Math.rint(value) ? Long.toString((long) value) : Double.toString(value);
    }

    public HttpServer serve(int port, BooleanSupplier healthy) throws IOException {
        HttpServer server = HttpServer.create(new InetSocketAddress(port), 0);
        server.createContext("/metrics", exchange -> respond(exchange, 200, render()));
        server.createContext("/health", exchange -> {
            boolean ok = healthy.getAsBoolean();
            respond(exchange, ok ? 200 : 503, ok ? "ok\n" : "not ready\n");
        });
        server.start();
        return server;
    }

    private static void respond(com.sun.net.httpserver.HttpExchange exchange, int status, String body)
            throws IOException {
        byte[] bytes = body.getBytes(StandardCharsets.UTF_8);
        exchange.getResponseHeaders().set("Content-Type", "text/plain; version=0.0.4");
        exchange.sendResponseHeaders(status, bytes.length);
        try (OutputStream os = exchange.getResponseBody()) {
            os.write(bytes);
        }
    }
}
