#!/bin/sh
# Runs ON THE VPS, called by .github/workflows/deploy.yml over SSH.
# stdin: line 1 = GHCR username, line 2 = short-lived GHCR token (job GITHUB_TOKEN).
set -eu

cd "$(dirname "$0")"
umask 077

COMPOSE="docker compose -f docker-compose.prod.yml --env-file .env"

fail() { echo "ERROR: $*" >&2; exit 1; }

# --- Preflight -------------------------------------------------------------
[ "$(uname -m)" = "x86_64" ] || fail "server is $(uname -m); the image is built for x86_64 (amd64) only"
docker info >/dev/null 2>&1 || fail "cannot talk to Docker as $(id -un). Add this user to the docker group (sudo usermod -aG docker $(id -un)), log out and back in, or deploy as root"
docker compose version >/dev/null 2>&1 || fail "Docker Compose v2 plugin missing (install docker-compose-plugin)"
[ -f app.env ] || fail "app.env was not uploaded"

# --- One-time secrets ------------------------------------------------------
# Generated on first deploy and NEVER overwritten: a new ENCRYPTION_KEY would
# make every stored Instagram token unreadable, a new POSTGRES_PASSWORD would
# lock the app out of its own database. Back this file up.
if [ ! -f secrets.env ]; then
  hex() { od -An -N"$1" -tx1 /dev/urandom | tr -d ' \n'; }
  {
    echo "POSTGRES_PASSWORD='$(hex 24)'"
    echo "NEXTAUTH_SECRET='$(hex 32)'"
    echo "CRON_SECRET='$(hex 32)'"
    echo "ENCRYPTION_KEY='$(hex 32)'"
  } > secrets.env.tmp
  mv secrets.env.tmp secrets.env
  echo "Generated secrets.env (first deploy)"
fi

# shellcheck disable=SC1091
. ./secrets.env
[ -n "${POSTGRES_PASSWORD:-}" ] || fail "secrets.env has no POSTGRES_PASSWORD"

{
  cat app.env
  cat secrets.env
  echo "DATABASE_URL='postgresql://openreply:${POSTGRES_PASSWORD}@postgres:5432/openreply'"
} > .env.tmp
mv .env.tmp .env
rm -f app.env

# --- Pull & start ----------------------------------------------------------
read -r GHCR_USER
read -r GHCR_TOKEN
printf '%s' "$GHCR_TOKEN" | docker login ghcr.io -u "$GHCR_USER" --password-stdin >/dev/null
pull_ok=0
$COMPOSE pull && pull_ok=1
docker logout ghcr.io >/dev/null 2>&1 || true
[ "$pull_ok" = 1 ] || fail "image pull failed"

if ! $COMPOSE up -d --remove-orphans --wait --wait-timeout 420; then
  echo "---- docker compose ps ----" >&2
  $COMPOSE ps -a >&2 || true
  echo "---- last 80 log lines ----" >&2
  $COMPOSE logs --tail 80 >&2 || true
  fail "stack did not become healthy"
fi

$COMPOSE ps
docker image prune -f >/dev/null 2>&1 || true
echo "Deploy finished."
