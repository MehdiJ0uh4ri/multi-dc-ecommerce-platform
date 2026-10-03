# data-tools: seeders (Jobs) and the load generator (Deployment). Built and pushed by
# `make data-tools-image` to registry.localhost:5000 until Phase 5 CI exists.
FROM python:3.13-slim@sha256:9d2e5553305c7c7b0097999bb17187c69b921ccd6bc9d40e4bb5ebe652c00285

ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY common/ common/
COPY seed/ seed/
COPY loadgen/ loadgen/
COPY tests/ tests/

# Non-root numeric user, so runAsNonRoot can be verified by the kubelet.
USER 10001:10001
CMD ["python", "loadgen/loadgen.py", "run"]
