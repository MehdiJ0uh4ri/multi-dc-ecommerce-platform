package local.platform.fraud;

import com.fasterxml.jackson.databind.node.ObjectNode;
import java.io.IOException;
import java.net.URI;
import java.net.URLEncoder;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.Base64;
import local.platform.fraud.Model.Alert;

/**
 * Indexes alerts into the logging Elasticsearch (es-logs, where Kibana runs). Authenticates
 * as the file-realm user fraud-notifier, which may only write fraud-alerts* (ECK spec.auth,
 * terraform/fraud-detection.tf). The document id is the alertId, so a redelivered alert
 * overwrites its own document.
 */
public final class AlertIndexer {
    /** Explicit mapping: without it, ids and countries would be analysed text. */
    static final String MAPPING = """
            {"mappings": {"properties": {
              "@timestamp": {"type": "date", "format": "epoch_millis"},
              "alertId": {"type": "keyword"}, "rule": {"type": "keyword"}, "severity": {"type": "keyword"},
              "userId": {"type": "long"}, "orderId": {"type": "long"}, "orderIds": {"type": "long"},
              "orderFee": {"type": "double"}, "unitPrice": {"type": "double"}, "quantityRatio": {"type": "double"},
              "shippingCountry": {"type": "keyword"}, "billingCountry": {"type": "keyword"},
              "paymentCount": {"type": "integer"}, "windowSeconds": {"type": "long"},
              "userPriorPayments": {"type": "long"}, "accountCreated": {"type": "boolean"},
              "paymentTs": {"type": "date", "format": "epoch_millis"},
              "detectedAt": {"type": "date", "format": "epoch_millis"},
              "notifiedAt": {"type": "date", "format": "epoch_millis"},
              "latencyMs": {"type": "long"}, "reason": {"type": "text"}
            }}}""";

    private final HttpClient http = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(5)).build();
    private final String baseUrl;
    private final String index;
    private final String authorization;

    public AlertIndexer(String baseUrl, String index, String user, String password) {
        this.baseUrl = baseUrl.replaceAll("/+$", "");
        this.index = index;
        this.authorization = "Basic " + Base64.getEncoder()
                .encodeToString((user + ":" + password).getBytes(StandardCharsets.UTF_8));
    }

    /** Creates the index with its mapping; an existing index is fine. */
    public void ensureIndex() throws IOException, InterruptedException {
        HttpResponse<String> r = send("PUT", "/" + index, MAPPING);
        if (r.statusCode() != 200 && !r.body().contains("resource_already_exists_exception")) {
            throw new IOException("create index " + index + ": " + r.statusCode() + " " + r.body());
        }
    }

    public static ObjectNode document(Alert alert, long notifiedAt) {
        ObjectNode doc = Json.MAPPER.valueToTree(alert);
        doc.put("@timestamp", alert.detectedAt());
        doc.put("notifiedAt", notifiedAt);
        doc.put("latencyMs", notifiedAt - alert.paymentTs());
        return doc;
    }

    public void index(Alert alert, long notifiedAt) throws IOException, InterruptedException {
        String id = URLEncoder.encode(alert.alertId(), StandardCharsets.UTF_8);
        HttpResponse<String> r = send("PUT", "/" + index + "/_doc/" + id,
                Json.MAPPER.writeValueAsString(document(alert, notifiedAt)));
        if (r.statusCode() != 200 && r.statusCode() != 201) {
            throw new IOException("index " + alert.alertId() + ": " + r.statusCode() + " " + r.body());
        }
    }

    private HttpResponse<String> send(String method, String path, String body) throws IOException, InterruptedException {
        HttpRequest request = HttpRequest.newBuilder(URI.create(baseUrl + path))
                .timeout(Duration.ofSeconds(10))
                .header("Authorization", authorization)
                .header("Content-Type", "application/json")
                .method(method, HttpRequest.BodyPublishers.ofString(body))
                .build();
        return http.send(request, HttpResponse.BodyHandlers.ofString());
    }
}
