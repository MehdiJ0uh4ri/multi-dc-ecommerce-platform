package local.platform.fraud;

import jakarta.mail.Message;
import jakarta.mail.MessagingException;
import jakarta.mail.Session;
import jakarta.mail.Transport;
import jakarta.mail.internet.InternetAddress;
import jakarta.mail.internet.MimeMessage;
import java.time.Instant;
import java.util.Properties;
import local.platform.fraud.Model.Alert;

/** Plain-text alert mail over unauthenticated SMTP (Mailpit, like notification-service). */
public final class AlertMail {
    private final Session session;
    private final String from;
    private final String to;

    public AlertMail(String host, int port, String from, String to) {
        Properties props = new Properties();
        props.put("mail.smtp.host", host);
        props.put("mail.smtp.port", Integer.toString(port));
        props.put("mail.smtp.auth", "false");
        props.put("mail.smtp.connectiontimeout", "5000");
        props.put("mail.smtp.timeout", "5000");
        this.session = Session.getInstance(props);
        this.from = from;
        this.to = to;
    }

    /** verify-phase5a searches Mailpit for "order <orderId>" in the subject. */
    public static String subject(Alert alert) {
        return String.format("[FRAUD %s] %s user %d order %d", alert.severity().toUpperCase(), alert.rule(),
                alert.userId(), alert.orderId());
    }

    public static String body(Alert alert, long latencyMs) {
        StringBuilder b = new StringBuilder();
        b.append(alert.reason()).append("\n\n");
        line(b, "alert id", alert.alertId());
        line(b, "rule", alert.rule());
        line(b, "severity", alert.severity());
        line(b, "user id", alert.userId());
        line(b, "order id", alert.orderId());
        line(b, "orders", alert.orderIds());
        line(b, "order fee", alert.orderFee());
        line(b, "unit price", alert.unitPrice());
        line(b, "quantity ratio", alert.quantityRatio());
        line(b, "shipping country", alert.shippingCountry());
        line(b, "billing country", alert.billingCountry());
        line(b, "earlier paid orders", alert.userPriorPayments());
        line(b, "payment time", Instant.ofEpochMilli(alert.paymentTs()));
        line(b, "detected", Instant.ofEpochMilli(alert.detectedAt()));
        line(b, "payment -> mail", String.format("%.1f s", latencyMs / 1000.0));
        b.append("\nKibana: data view fraud-alerts* (docs/fraud-detection.md)\n");
        return b.toString();
    }

    private static void line(StringBuilder b, String name, Object value) {
        if (value != null) {
            b.append(String.format("%-20s %s%n", name + ":", value));
        }
    }

    public void send(Alert alert, long latencyMs) throws MessagingException {
        MimeMessage message = new MimeMessage(session);
        message.setFrom(new InternetAddress(from));
        message.setRecipients(Message.RecipientType.TO, InternetAddress.parse(to));
        message.setSubject(subject(alert));
        message.setHeader("X-Fraud-Alert-Id", alert.alertId());
        message.setText(body(alert, latencyMs));
        Transport.send(message);
    }
}
