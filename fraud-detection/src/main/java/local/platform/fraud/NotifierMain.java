package local.platform.fraud;

import java.time.Duration;
import java.util.List;
import java.util.Map;
import java.util.Properties;
import java.util.concurrent.atomic.AtomicBoolean;
import local.platform.fraud.Model.Alert;
import org.apache.kafka.clients.consumer.ConsumerConfig;
import org.apache.kafka.clients.consumer.ConsumerRecord;
import org.apache.kafka.clients.consumer.KafkaConsumer;
import org.apache.kafka.common.errors.WakeupException;
import org.apache.kafka.common.serialization.StringDeserializer;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

/**
 * fraud-notifier: fraud-alerts -> mail to Mailpit, then a document in es-logs.
 *
 * <p>notification-service cannot be reused: its topics are fixed in @KafkaListener
 * annotations. Offsets are committed after each batch, so an alert is never lost; a
 * crash can repeat a mail. Mail is retried until it succeeds, because the mail is the
 * alert. Indexing is retried a few times and then counted as failed
 * (fraud_notifier_index_failures_total), so an Elasticsearch outage never delays mail.
 */
public final class NotifierMain {
    private static final Logger LOG = LoggerFactory.getLogger(NotifierMain.class);

    private NotifierMain() {
    }

    public static void main(String[] args) throws Exception {
        Map<String, String> env = System.getenv();
        String bootstrap = Config.get(env, "KAFKA_BOOTSTRAP", "kafka-dc2-kafka-bootstrap:9092");
        String topic = Config.get(env, "TOPIC_ALERTS", "fraud-alerts");
        AlertMail mail = new AlertMail(Config.get(env, "SMTP_HOST", "mailpit-smtp"),
                Integer.parseInt(Config.get(env, "SMTP_PORT", "25")),
                Config.get(env, "MAIL_FROM", "fraud-detection@platform.local"),
                Config.get(env, "MAIL_TO", "fraud-team@platform.local"));
        String esUrl = Config.get(env, "ES_URL", "");
        AlertIndexer indexer = esUrl.isEmpty() ? null : new AlertIndexer(esUrl,
                Config.get(env, "ES_INDEX", "fraud-alerts"), Config.get(env, "ES_USER", "fraud-notifier"),
                Config.get(env, "ES_PASSWORD", ""));

        Metrics metrics = new Metrics();
        AtomicBoolean running = new AtomicBoolean(true);
        var server = metrics.serve(Integer.parseInt(Config.get(env, "METRICS_PORT", "9000")), running::get);

        Properties props = new Properties();
        props.put(ConsumerConfig.BOOTSTRAP_SERVERS_CONFIG, bootstrap);
        props.put(ConsumerConfig.GROUP_ID_CONFIG, Config.get(env, "GROUP_ID", "fraud-notifier"));
        props.put(ConsumerConfig.ENABLE_AUTO_COMMIT_CONFIG, false);
        props.put(ConsumerConfig.AUTO_OFFSET_RESET_CONFIG, "earliest");
        props.put(ConsumerConfig.MAX_POLL_RECORDS_CONFIG, 50);
        KafkaConsumer<String, String> consumer =
                new KafkaConsumer<>(props, new StringDeserializer(), new StringDeserializer());

        Thread main = Thread.currentThread();
        Runtime.getRuntime().addShutdownHook(new Thread(() -> {
            running.set(false);
            consumer.wakeup();
            try {
                main.join(20_000);
            } catch (InterruptedException ignored) {
                Thread.currentThread().interrupt();
            }
            server.stop(0);
        }));

        if (indexer != null) {
            retry("create index", 10, indexer::ensureIndex);
        }
        try {
            consumer.subscribe(List.of(topic));
            while (running.get()) {
                for (ConsumerRecord<String, String> record : consumer.poll(Duration.ofMillis(500))) {
                    handle(record, mail, indexer, metrics, running);
                }
                consumer.commitSync();
            }
        } catch (WakeupException e) {
            if (running.get()) {
                throw e;
            }
        } finally {
            consumer.close(Duration.ofSeconds(5));
        }
    }

    static void handle(ConsumerRecord<String, String> record, AlertMail mail, AlertIndexer indexer, Metrics metrics,
                       AtomicBoolean running) throws InterruptedException {
        Alert alert;
        try {
            alert = Json.MAPPER.readValue(record.value(), Alert.class);
        } catch (Exception e) {
            metrics.inc("fraud_notifier_invalid_total");
            LOG.error("unreadable alert at offset {}: {}", record.offset(), record.value());
            return;
        }
        for (int attempt = 0; running.get(); attempt++) {
            try {
                long latency = System.currentTimeMillis() - alert.paymentTs();
                mail.send(alert, latency);
                metrics.inc("fraud_notifier_mails_total", "rule", alert.rule());
                metrics.observeLatency(alert.rule(), latency / 1000.0);
                LOG.info("mailed {} ({} ms after payment)", alert.alertId(), latency);
                break;
            } catch (Exception e) {
                metrics.inc("fraud_notifier_mail_errors_total");
                LOG.warn("mail {} failed (attempt {}): {}", alert.alertId(), attempt + 1, e.toString());
                Thread.sleep(Math.min(10_000, 500L << Math.min(attempt, 5)));
            }
        }
        if (indexer != null) {
            long notifiedAt = System.currentTimeMillis();
            try {
                retry("index " + alert.alertId(), 3, () -> indexer.index(alert, notifiedAt));
                metrics.inc("fraud_notifier_indexed_total", "rule", alert.rule());
            } catch (Exception e) {
                metrics.inc("fraud_notifier_index_failures_total");
                LOG.error("giving up indexing {}: {}", alert.alertId(), e.toString());
            }
        }
    }

    interface Action {
        void run() throws Exception;
    }

    static void retry(String what, int attempts, Action action) throws Exception {
        for (int attempt = 1; ; attempt++) {
            try {
                action.run();
                return;
            } catch (Exception e) {
                if (attempt >= attempts) {
                    throw e;
                }
                LOG.warn("{} failed (attempt {}/{}): {}", what, attempt, attempts, e.toString());
                Thread.sleep(1000L * attempt);
            }
        }
    }
}
