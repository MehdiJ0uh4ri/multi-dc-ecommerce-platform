package local.platform.fraud;

import java.util.List;
import local.platform.fraud.Model.Alert;
import local.platform.fraud.Model.OrderContext;
import local.platform.fraud.Model.PaidOrder;

/**
 * The three rules. Each returns an alert or null. They only see what a production detector
 * would: never the loadgen `scenario` header.
 */
public final class Rules {
    public static final String VELOCITY = "VELOCITY";
    public static final String AMOUNT_ANOMALY = "AMOUNT_ANOMALY";
    public static final String GEO_MISMATCH = "GEO_MISMATCH";

    private Rules() {
    }

    /** Shipping country differs from billing country on a paid order. */
    public static Alert geoMismatch(PaidOrder order, OrderContext context, long now) {
        String shipping = context.shippingCountry();
        String billing = context.billingCountry();
        if (shipping == null || billing == null || shipping.equalsIgnoreCase(billing)) {
            return null;
        }
        return new Alert(GEO_MISMATCH + "-" + order.orderId(), GEO_MISMATCH, "medium", order.userId(),
                order.orderId(), null, order.orderFee(), order.unitPrice(), null, shipping, billing, null, null,
                null, context.accountCreated(), order.paymentTs(), now,
                "paid order ships to " + shipping + " but bills to " + billing);
    }

    /**
     * Paid amount is at least `factor` times the product's unit price, i.e. an implausible
     * quantity (normal baskets hold 1-3 units). Payments carry no amount, so orderFee comes
     * from the orders CDC stream (upstream finding #9). Severity is high when the account has
     * fewer than `lowHistory` earlier paid orders.
     */
    public static Alert amountAnomaly(PaidOrder order, long priorPayments, double factor, int lowHistory, long now) {
        Double price = order.unitPrice();
        if (price == null || price <= 0) {
            return null;
        }
        double ratio = order.orderFee() / price;
        if (ratio < factor) {
            return null;
        }
        boolean lowHistoryAccount = priorPayments < lowHistory;
        return new Alert(AMOUNT_ANOMALY + "-" + order.orderId(), AMOUNT_ANOMALY, lowHistoryAccount ? "high" : "medium",
                order.userId(), order.orderId(), null, order.orderFee(), price, Math.round(ratio * 100) / 100.0,
                null, null, null, null, priorPayments, null, order.paymentTs(), now,
                String.format("paid %.2f = %.1f x unit price %.2f; account has %d earlier paid order(s)",
                        order.orderFee(), ratio, price, priorPayments));
    }

    /** `count` or more paid orders by one user within `windowSeconds` (event time). */
    public static Alert velocity(long userId, List<Long> orderIds, long firstTs, long lastTs, long windowSeconds,
                                 long now) {
        return new Alert(VELOCITY + "-" + userId + "-" + firstTs, VELOCITY, "high", userId,
                orderIds.get(orderIds.size() - 1), List.copyOf(orderIds), null, null, null, null, null,
                orderIds.size(), windowSeconds, null, null, lastTs, now,
                String.format("%d paid orders in %.1f s (limit window %d s)", orderIds.size(),
                        (lastTs - firstTs) / 1000.0, windowSeconds));
    }
}
