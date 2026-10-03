package local.platform.fraud;

import com.fasterxml.jackson.databind.JsonNode;
import java.nio.charset.StandardCharsets;
import org.apache.kafka.common.serialization.Deserializer;
import org.apache.kafka.common.serialization.Serde;
import org.apache.kafka.common.serialization.Serdes;
import org.apache.kafka.common.serialization.Serializer;

/**
 * Serdes for the product-price GlobalKTable read straight from dbproduct.public.product.
 *
 * <p>A global store restores by copying the topic's raw bytes, while live updates are
 * deserialized and serialized again. Both forms must read back the same way:
 * <ul>
 *   <li>key: the topic's Debezium key {"id":N} (JsonConverter, schemas off, after the
 *       ReplaceField rename of ADR-021). The serializer writes exactly that form.</li>
 *   <li>value: the Debezium envelope on the topic, or the plain price the serializer
 *       writes. A deletion (after = null) or a tombstone reads as null, which removes the row.</li>
 * </ul>
 */
public final class ProductSerdes {
    private ProductSerdes() {
    }

    public static Serde<String> key() {
        Serializer<String> serializer = (topic, id) ->
                id == null ? null : ("{\"id\":" + Long.parseLong(id) + "}").getBytes(StandardCharsets.UTF_8);
        Deserializer<String> deserializer = (topic, bytes) -> {
            JsonNode node = bytes == null ? null : Json.tree(new String(bytes, StandardCharsets.UTF_8));
            return node != null && node.path("id").canConvertToLong() ? Long.toString(node.path("id").asLong()) : null;
        };
        return Serdes.serdeFrom(serializer, deserializer);
    }

    public static Serde<Double> price() {
        Serializer<Double> serializer = (topic, price) ->
                price == null ? null : Double.toString(price).getBytes(StandardCharsets.UTF_8);
        Deserializer<Double> deserializer = (topic, bytes) -> {
            if (bytes == null) {
                return null;
            }
            String text = new String(bytes, StandardCharsets.UTF_8).trim();
            if (!text.startsWith("{")) {
                try {
                    return Double.valueOf(text);
                } catch (NumberFormatException e) {
                    return null;
                }
            }
            JsonNode envelope = Json.tree(text);
            JsonNode price = envelope == null ? null : envelope.path("after").path("price_unit");
            return price != null && price.isNumber() ? price.asDouble() : null;
        };
        return Serdes.serdeFrom(serializer, deserializer);
    }
}
