.PHONY: init up down restart logs ps pull test cache backup psql

init:      ## Create .env with generated secrets
	./scripts/init-env.sh

up:        ## Start the gateway and database
	docker compose up -d

down:      ## Stop everything (data is kept)
	docker compose down

restart:   ## Reload after editing config/litellm.yaml or .env
	docker compose up -d --force-recreate litellm

logs:      ## Follow gateway logs
	docker compose logs -f litellm

ps:
	docker compose ps

pull:      ## Fetch the image tags named in docker-compose.yml / .env
	docker compose pull

test:      ## Health check; pass MODEL=provider/model to also send a request
	./scripts/smoke-test.sh $(MODEL)

cache:     ## Cached vs uncached prompt tokens per model per day
	docker compose exec -T db psql -U litellm litellm < scripts/cache-report.sql

backup:    ## Dump the database to backups/
	mkdir -p backups
	docker compose exec -T db pg_dump -U litellm litellm | gzip > backups/litellm-$$(date +%Y%m%d-%H%M%S).sql.gz

psql:
	docker compose exec db psql -U litellm litellm
