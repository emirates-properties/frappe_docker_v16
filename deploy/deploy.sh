#!/usr/bin/env bash
# Server-side deploy script for frappe_docker.
# Run this on the server from a checkout of this repo (or scp'd deploy kit).
#
# Usage:
#   1. Edit ./deploy/.env on the server (or scp it in).
#   2. Log in to ghcr.io first:  echo "$GHCR_TOKEN" | docker login ghcr.io -u <github-user> --password-stdin
#   3. ./deploy/deploy.sh up        (first time or after image tag change)
#      ./deploy/deploy.sh create    (only once: creates the Frappe site)
#      ./deploy/deploy.sh migrate   (after rolling a new image version)
#      ./deploy/deploy.sh logs      (tail all services)
#      ./deploy/deploy.sh down      (stop stack; keeps volumes)
set -euo pipefail

PROJECT_NAME="frappe"
ENV_FILE="./deploy/.env"
GENERATED="./deploy/docker-compose.generated.yaml"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: $ENV_FILE is missing. Copy deploy/.env.server to deploy/.env and fill it in." >&2
  exit 1
fi

render() {
  docker compose --env-file "$ENV_FILE" \
    -f compose.yaml \
    -f overrides/compose.mariadb.yaml \
    -f overrides/compose.redis.yaml \
    -f overrides/compose.https.yaml \
    config > "$GENERATED"
}

dc() {
  docker compose --project-name "$PROJECT_NAME" --env-file "$ENV_FILE" -f "$GENERATED" "$@"
}

cmd="${1:-up}"
case "$cmd" in
  up)
    render
    dc pull
    dc up -d
    dc ps
    ;;
  create)
    render
    # Read the site name from SITES_RULE in .env (strip Host(`...`))
    site="$(grep -E '^FRAPPE_SITE_NAME_HEADER=' "$ENV_FILE" | cut -d= -f2-)"
    admin_pw="${ADMIN_PASSWORD:-}"
    if [[ -z "$admin_pw" ]]; then
      read -rsp "Admin password for new site: " admin_pw; echo
    fi
    db_root="$(grep -E '^DB_PASSWORD=' "$ENV_FILE" | cut -d= -f2-)"
    dc exec backend bench new-site \
      --mariadb-user-host-login-scope='%' \
      --db-root-password "$db_root" \
      --admin-password "$admin_pw" \
      --install-app erpnext \
      "$site"
    ;;
  migrate)
    render
    dc pull
    dc up -d
    site="$(grep -E '^FRAPPE_SITE_NAME_HEADER=' "$ENV_FILE" | cut -d= -f2-)"
    dc exec backend bench --site "$site" migrate
    ;;
  logs)    render; dc logs -f --tail=100 ;;
  ps)      render; dc ps ;;
  down)    render; dc down ;;
  restart) render; dc restart ;;
  *) echo "Unknown command: $cmd" >&2; exit 2 ;;
esac
