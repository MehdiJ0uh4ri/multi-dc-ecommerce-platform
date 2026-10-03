TF_DIR      := terraform
ANSIBLE_DIR := ansible
K3D_CONFIG  := k3d/multidc-cluster.yaml
# Phase 4.5 image; pushed through the host port of the k3d registry, pulled in-cluster as
# registry.localhost:5000/platform/data-tools (charts/data-tools).
DATA_TOOLS_VERSION := $(shell cat data-tools/VERSION)
DATA_TOOLS_IMAGE   := localhost:5000/platform/data-tools:$(DATA_TOOLS_VERSION)

.PHONY: help tools check-tools app-init cluster-create tf-init tf-validate tf-plan ansible-check \
        data-tools-image data-tools-test olist-prepare keycloak-config verify-phase4.5

help:
	@grep -E '^[a-z0-9.-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-18s %s\n", $$1, $$2}'

tools: ## Install pinned terraform/kubectl/helm/k3d into ~/.local/bin (Ansible)
	cd $(ANSIBLE_DIR) && ansible-playbook playbooks/bootstrap-tools.yml

check-tools: ## Report which required CLIs are present
	./scripts/check-tools.sh

app-init: ## Fetch the app submodule at the pinned commit
	git submodule update --init --recursive app

cluster-create: ## Create the proposed multidc k3d cluster (ADR-001)
	k3d cluster create --config $(K3D_CONFIG)

tf-init: ## terraform init (local backend)
	terraform -chdir=$(TF_DIR) init

tf-validate: ## terraform fmt check + validate (no cluster needed)
	terraform -chdir=$(TF_DIR) fmt -check -recursive
	terraform -chdir=$(TF_DIR) validate

tf-plan: ## terraform plan (needs a running cluster)
	terraform -chdir=$(TF_DIR) plan

tf-apply: ## terraform apply (needs a running cluster)
	terraform -chdir=$(TF_DIR) apply

tf-plan-minimal: ## terraform plan with the minimal test profile (terraform/profiles/minimal.tfvars)
	terraform -chdir=$(TF_DIR) plan -var-file=profiles/minimal.tfvars

tf-apply-minimal: ## terraform apply with the minimal test profile
	terraform -chdir=$(TF_DIR) apply -var-file=profiles/minimal.tfvars

secrets: ## Generate data-store passwords into terraform/secrets.auto.tfvars.json (Ansible)
	cd $(ANSIBLE_DIR) && ansible-playbook playbooks/bootstrap-secrets.yml

verify-phase1: ## Check node taints, DC pinning and NetworkPolicy isolation (creates temp pods)
	./scripts/verify-phase1.sh

verify-phase2: ## Check operators, DC1 data stores and network access (creates temp pods)
	./scripts/verify-phase2.sh

verify-phase3: ## End-to-end order through APISIX -> order-service -> Postgres -> Debezium -> Kafka
	./scripts/verify-phase3.sh

verify-phase4: ## DC2: operators, stores, MirrorMaker 2, sinks, services, cross-DC paths (creates temp pods)
	./scripts/verify-phase4.sh

verify-phase4.5: ## Data layer: seed Jobs, loadgen fraud patterns, order-context/SUCCESSFUL in both DCs
	./scripts/verify-phase4.5.sh

data-tools-image: ## Phase 4.5: build data-tools (seeders + loadgen) and push to the k3d registry
	docker build -t $(DATA_TOOLS_IMAGE) data-tools
	docker push $(DATA_TOOLS_IMAGE)

data-tools-test: ## Phase 4.5: unit tests of data-tools inside the image (no cluster needed)
	docker build -q -t $(DATA_TOOLS_IMAGE) data-tools >/dev/null
	docker run --rm $(DATA_TOOLS_IMAGE) python -m unittest discover -s tests

olist-prepare: ## Phase 4.5: Olist CSVs in data-tools/data/ -> olist-replay.jsonl.gz (ARGS="--start 2017-11-01 --limit 5000")
	docker build -q -t $(DATA_TOOLS_IMAGE) data-tools >/dev/null
	docker run --rm --user $$(id -u):$$(id -g) -v $(CURDIR)/data-tools/data:/data $(DATA_TOOLS_IMAGE) \
	  python seed/seed_orders.py prepare --input /data --output /data/olist-replay.jsonl.gz $(ARGS)

keycloak-config: ## Phase 4.5: Keycloak client platform-seeder (terraform/keycloak, via a port-forward)
	@kubectl --context k3d-multidc -n dc1-core port-forward svc/keycloak 18080:8080 >/dev/null 2>&1 & pf=$$!; \
	trap 'kill $$pf 2>/dev/null' EXIT; \
	for i in $$(seq 1 30); do curl -sf -o /dev/null http://localhost:18080/realms/master && break; sleep 1; done; \
	terraform -chdir=$(TF_DIR)/keycloak init -input=false >/dev/null && \
	terraform -chdir=$(TF_DIR)/keycloak apply -var-file=../secrets.auto.tfvars.json

verify-phase6: ## Observability: Prometheus targets, dashboards, logs in Elasticsearch, Icinga checks
	./scripts/verify-phase6.sh

verify-phase7: ## Chaos Mesh ready + experiment manifests accepted by the API (server dry-run)
	./scripts/verify-phase7.sh

chaos-kafka: ## Phase 7: kill the DC1 Kafka broker and measure degradation/recovery
	./scripts/chaos-demo.sh kafka-broker-kill

chaos-postgres: ## Phase 7: kill the DC1 PostgreSQL primary (CloudNativePG failover)
	./scripts/chaos-demo.sh postgres-primary-kill

chaos-partition: ## Phase 7: partition DC1 <-> DC2 replication (MirrorMaker 2)
	./scripts/chaos-demo.sh dc-partition

chaos-latency: ## Phase 7: add WAN latency between DC1 and DC2
	./scripts/chaos-demo.sh cross-dc-latency

ansible-check: ## Syntax-check all playbooks
	cd $(ANSIBLE_DIR) && for p in playbooks/*.yml; do ansible-playbook --syntax-check $$p || exit 1; done
