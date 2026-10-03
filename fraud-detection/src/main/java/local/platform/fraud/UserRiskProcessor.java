package local.platform.fraud;

import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.function.LongSupplier;
import local.platform.fraud.Model.Alert;
import local.platform.fraud.Model.PaidOrder;
import local.platform.fraud.Model.UserState;
import local.platform.fraud.Model.UserState.Recent;
import org.apache.kafka.streams.processor.api.Processor;
import org.apache.kafka.streams.processor.api.ProcessorContext;
import org.apache.kafka.streams.processor.api.Record;
import org.apache.kafka.streams.state.KeyValueStore;

/**
 * Per-user rules over paid orders keyed by userId: velocity and amount anomaly (which needs
 * the user's history). State per user: number of paid orders, the paid orders inside the
 * velocity window, and a quiet period so one burst raises one alert.
 */
public class UserRiskProcessor implements Processor<String, PaidOrder, String, Alert> {
    public static final String STORE = "user-risk";

    private final Config config;
    private final LongSupplier clock;
    private ProcessorContext<String, Alert> context;
    private KeyValueStore<String, UserState> store;

    public UserRiskProcessor(Config config, LongSupplier clock) {
        this.config = config;
        this.clock = clock;
    }

    @Override
    public void init(ProcessorContext<String, Alert> context) {
        this.context = context;
        this.store = context.getStateStore(STORE);
    }

    @Override
    public void process(Record<String, PaidOrder> record) {
        PaidOrder order = record.value();
        if (order == null) {
            return;
        }
        String key = Long.toString(order.userId());
        UserState state = store.get(key);
        if (state == null) {
            state = new UserState(0, List.of(), 0);
        }
        // At-least-once delivery can repeat a payment; count each order once.
        boolean duplicate = state.recent().stream().anyMatch(r -> r.orderId() == order.orderId());
        if (duplicate) {
            return;
        }
        long now = clock.getAsLong();

        Alert amount = Rules.amountAnomaly(order, state.paidOrders(), config.amountQuantityFactor(),
                config.lowHistoryPayments(), now);
        if (amount != null) {
            context.forward(record.withKey(key).withValue(amount));
        }

        long window = config.velocityWindow().toMillis();
        List<Recent> recent = new ArrayList<>();
        for (Recent r : state.recent()) {
            if (r.ts() > order.paymentTs() - window) {
                recent.add(r);
            }
        }
        recent.add(new Recent(order.paymentTs(), order.orderId()));
        recent.sort(Comparator.comparingLong(Recent::ts));

        long quietUntil = state.velocityQuietUntil();
        if (recent.size() >= config.velocityCount() && order.paymentTs() >= quietUntil) {
            Alert velocity = Rules.velocity(order.userId(), recent.stream().map(Recent::orderId).toList(),
                    recent.get(0).ts(), order.paymentTs(), config.velocityWindow().toSeconds(), now);
            context.forward(record.withKey(key).withValue(velocity));
            quietUntil = order.paymentTs() + window;
        }
        store.put(key, new UserState(state.paidOrders() + 1, recent, quietUntil));
    }
}
