package local.platform.fraud;

import java.util.List;
import java.util.Properties;
import java.util.Set;
import java.util.concurrent.CountDownLatch;
import java.util.stream.Collectors;
import org.apache.kafka.clients.admin.Admin;
import org.apache.kafka.clients.admin.AdminClientConfig;
import org.apache.kafka.clients.admin.NewTopic;
import org.apache.kafka.common.errors.TopicExistsException;
import org.apache.kafka.streams.KafkaStreams;
import org.apache.kafka.streams.StreamsConfig;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

/** fraud-detector: the Kafka Streams application (FraudTopology) on kafka-dc2. */
public final class DetectorMain {
    private static final Logger LOG = LoggerFactory.getLogger(DetectorMain.class);

    private DetectorMain() {
    }

    public static void main(String[] args) throws Exception {
        Config config = Config.fromEnv(System.getenv());
        Metrics metrics = new Metrics();
        ensureTopics(config);

        Properties props = new Properties();
        props.put(StreamsConfig.APPLICATION_ID_CONFIG, config.applicationId());
        props.put(StreamsConfig.BOOTSTRAP_SERVERS_CONFIG, config.bootstrap());
        props.put(StreamsConfig.STATE_DIR_CONFIG, config.stateDir());
        // Alerts must leave within seconds: no record cache holding results back, and
        // frequent commits. At-least-once; the notifier indexes by alertId, so a repeat
        // overwrites the same document (a repeated mail is possible).
        props.put(StreamsConfig.STATESTORE_CACHE_MAX_BYTES_CONFIG, 0);
        props.put(StreamsConfig.COMMIT_INTERVAL_MS_CONFIG, 1000);
        props.put(StreamsConfig.consumerPrefix("auto.offset.reset"), "earliest");

        KafkaStreams streams = new KafkaStreams(FraudTopology.build(config, System::currentTimeMillis, metrics), props);
        streams.setUncaughtExceptionHandler(e -> {
            LOG.error("stream thread failed", e);
            return org.apache.kafka.streams.errors.StreamsUncaughtExceptionHandler.StreamThreadExceptionResponse
                    .REPLACE_THREAD;
        });
        var server = metrics.serve(config.metricsPort(), () -> streams.state() == KafkaStreams.State.RUNNING
                || streams.state() == KafkaStreams.State.REBALANCING);

        CountDownLatch stopped = new CountDownLatch(1);
        Runtime.getRuntime().addShutdownHook(new Thread(() -> {
            streams.close();
            server.stop(0);
            stopped.countDown();
        }));
        streams.start();
        LOG.info("fraud-detector started: {}", config);
        stopped.await();
    }

    /**
     * Kafka Streams stops on a missing source topic. On a fresh DC2 the mirrored topics only
     * appear once DC1 has produced to them, so they are created here (1 partition, broker
     * default replication). MirrorMaker 2 then writes into the existing topics.
     */
    static void ensureTopics(Config config) throws Exception {
        List<String> names = List.of(config.paymentsTopic(), config.ordersTopic(), config.productsTopic(),
                config.contextTopic(), config.alertsTopic());
        Properties props = new Properties();
        props.put(AdminClientConfig.BOOTSTRAP_SERVERS_CONFIG, config.bootstrap());
        try (Admin admin = Admin.create(props)) {
            Set<String> existing = admin.listTopics().names().get();
            List<NewTopic> missing = names.stream().filter(n -> !existing.contains(n))
                    .map(n -> new NewTopic(n, java.util.Optional.of(1), java.util.Optional.empty()))
                    .collect(Collectors.toList());
            for (var entry : admin.createTopics(missing).values().entrySet()) {
                try {
                    entry.getValue().get();
                    LOG.info("created topic {}", entry.getKey());
                } catch (java.util.concurrent.ExecutionException e) {
                    if (!(e.getCause() instanceof TopicExistsException)) {
                        throw e;
                    }
                }
            }
        }
    }
}
