COMPOSE ?= docker compose

.PHONY: help init up down restart logs ps check session

init: ## One-time setup: .env from example + generate the llama API key
	@test -f .env || cp .env.example .env
	@test -f secrets/llama_api_key || { mkdir -p secrets; head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > secrets/llama_api_key; chmod 600 secrets/llama_api_key; }
	@echo ".env and secrets/llama_api_key are ready (both gitignored)"

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*##' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*## "}{printf "  \033[36m%-8s\033[0m %s\n", $$1, $$2}'

up: ## Start the monitoring stack (node-exporter, prometheus, grafana)
	$(COMPOSE) up -d

down: ## Stop and remove the monitoring stack
	$(COMPOSE) down

restart: ## Restart the monitoring stack
	$(COMPOSE) restart

logs: ## Tail monitoring logs
	$(COMPOSE) logs -f --tail=100

ps: ## Show monitoring status
	$(COMPOSE) ps

check: ## Validate compose + prometheus configs
	$(COMPOSE) config -q
	docker run --rm --entrypoint promtool -v $(PWD)/prometheus:/cfg:ro -v $(PWD)/secrets/llama_api_key:/etc/prometheus/keys/llama_api_key:ro prom/prometheus:v3.16.0 check config /cfg/prometheus.yml
	@echo "Configs OK"

session: ## Start an inference session (./run.sh: VRAM tuning + llama-server + live logs)
	./run.sh
