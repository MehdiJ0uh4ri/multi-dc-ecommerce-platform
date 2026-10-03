# Phase 5a: fraud-detector (Kafka Streams) and fraud-notifier, one image. Built and pushed by
# `make fraud-image` until Phase 5 CI exists. The build stage runs the unit tests.
FROM maven:3.9-eclipse-temurin-21@sha256:c2a2c58516d160f43b50f12baa427ca86989e0bc942609e04aff61da5d9a7d74 AS build
WORKDIR /src
COPY pom.xml .
RUN mvn -B -q dependency:go-offline
COPY src/ src/
RUN mvn -B -q package

# glibc base (not Alpine): RocksDB's JNI library, used by the Streams state stores, needs it.
FROM eclipse-temurin:21-jre@sha256:49e21e16e3c86eb7816a44a67549910ed090fbeb40c29c525d58bf5e02e91b0f
COPY --from=build /src/target/fraud-detection.jar /app/fraud-detection.jar
USER 10001:10001
ENV JAVA_TOOL_OPTIONS="-XX:MaxRAMPercentage=60 -Djava.io.tmpdir=/tmp"
ENTRYPOINT ["java", "-cp", "/app/fraud-detection.jar"]
CMD ["local.platform.fraud.DetectorMain"]
