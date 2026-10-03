package local.platform.fraud;

import com.fasterxml.jackson.databind.DeserializationFeature;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import org.apache.kafka.common.errors.SerializationException;
import org.apache.kafka.common.serialization.Deserializer;
import org.apache.kafka.common.serialization.Serde;
import org.apache.kafka.common.serialization.Serdes;
import org.apache.kafka.common.serialization.Serializer;
import local.platform.fraud.Model.Order;
import local.platform.fraud.Model.OrderContext;
import local.platform.fraud.Model.Payment;

/** Parsing of the input topics. Every parser returns null for input it cannot use. */
public final class Json {
    public static final ObjectMapper MAPPER = new ObjectMapper()
            .configure(DeserializationFeature.FAIL_ON_UNKNOWN_PROPERTIES, false);

    private Json() {
    }

    static JsonNode tree(String text) {
        if (text == null) {
            return null;
        }
        try {
            JsonNode node = MAPPER.readTree(text);
            return node != null && node.isObject() ? node : null;
        } catch (IOException e) {
            return null;
        }
    }

    /** {"paymentId":1,"isPayed":true,"paymentStatus":"COMPLETED","orderId":5,"userId":7} (gson). */
    public static Payment payment(String text) {
        JsonNode node = tree(text);
        if (node == null || !node.path("orderId").canConvertToLong() || !node.path("userId").canConvertToLong()) {
            return null;
        }
        return MAPPER.convertValue(node, Payment.class);
    }

    /**
     * Debezium envelope with schemas disabled and decimal.handling.mode=double
     * (helm-values/dc1-core/cdc-connectors.yaml). Only creations (op c, snapshot r) count:
     * an update would pair the same payment with the order a second time.
     */
    public static Order orderCreated(String text) {
        JsonNode node = tree(text);
        if (node == null) {
            return null;
        }
        String op = node.path("op").asText();
        JsonNode after = node.path("after");
        if (!("c".equals(op) || "r".equals(op)) || !after.path("order_id").canConvertToLong()) {
            return null;
        }
        JsonNode product = after.path("product_id");
        return new Order(after.path("order_id").asLong(),
                product.canConvertToLong() ? product.asLong() : null,
                after.path("order_fee").asDouble(0));
    }

    public static OrderContext orderContext(String text) {
        JsonNode node = tree(text);
        if (node == null || !node.path("orderId").canConvertToLong()) {
            return null;
        }
        return MAPPER.convertValue(node, OrderContext.class);
    }

    public static <T> Serde<T> serde(Class<T> type) {
        Serializer<T> serializer = (topic, value) -> {
            if (value == null) {
                return null;
            }
            try {
                return MAPPER.writeValueAsBytes(value);
            } catch (IOException e) {
                throw new SerializationException(e);
            }
        };
        Deserializer<T> deserializer = (topic, bytes) -> {
            if (bytes == null) {
                return null;
            }
            try {
                return MAPPER.readValue(bytes, type);
            } catch (IOException e) {
                throw new SerializationException("cannot read " + type.getSimpleName() + ": "
                        + new String(bytes, StandardCharsets.UTF_8), e);
            }
        };
        return Serdes.serdeFrom(serializer, deserializer);
    }
}
