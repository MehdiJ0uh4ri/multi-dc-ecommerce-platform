package local.platform.fraud;

import com.fasterxml.jackson.annotation.JsonIgnoreProperties;
import com.fasterxml.jackson.annotation.JsonInclude;
import java.util.List;

/** Messages the detector reads, keeps and writes. */
public final class Model {
    private Model() {
    }

    /** payment-service KafkaPaymentDto on topic SUCCESSFUL; ts = Kafka record timestamp. */
    @JsonIgnoreProperties(ignoreUnknown = true)
    public record Payment(Long paymentId, Boolean isPayed, String paymentStatus, Long orderId, Long userId, long ts) {
        Payment withTs(long timestamp) {
            return new Payment(paymentId, isPayed, paymentStatus, orderId, userId, timestamp);
        }
    }

    /** Row image of a created order (Debezium, dborder.public.orders). */
    public record Order(long orderId, Long productId, double orderFee) {
    }

    /** Platform-owned checkout context (topic order-context, ADR-030). */
    @JsonIgnoreProperties(ignoreUnknown = true)
    public record OrderContext(Long orderId, Long userId, String shippingCountry, String billingCountry,
                               Boolean accountCreated) {
    }

    /** A payment joined with its order and, when known, the product's unit price. */
    public record PaidOrder(long orderId, long userId, Long productId, double orderFee, Double unitPrice,
                            long paymentTs) {
        static PaidOrder of(Payment payment, Order order) {
            return new PaidOrder(order.orderId(), payment.userId(), order.productId(), order.orderFee(), null,
                    payment.ts());
        }

        PaidOrder withUnitPrice(Double price) {
            return new PaidOrder(orderId, userId, productId, orderFee, price, paymentTs);
        }
    }

    /** Per-user state of UserRiskProcessor. */
    public record UserState(long paidOrders, List<Recent> recent, long velocityQuietUntil) {
        public record Recent(long ts, long orderId) {
        }
    }

    /** Topic fraud-alerts. alertId is stable, so re-deliveries index the same document. */
    @JsonInclude(JsonInclude.Include.NON_NULL)
    @JsonIgnoreProperties(ignoreUnknown = true)
    public record Alert(
            String alertId,
            String rule,
            String severity,
            Long userId,
            Long orderId,
            List<Long> orderIds,
            Double orderFee,
            Double unitPrice,
            Double quantityRatio,
            String shippingCountry,
            String billingCountry,
            Integer paymentCount,
            Long windowSeconds,
            Long userPriorPayments,
            Boolean accountCreated,
            long paymentTs,
            long detectedAt,
            String reason) {
    }
}
