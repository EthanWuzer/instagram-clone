#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

# ── preflight ──────────────────────────────────────────────────────────────
command -v docker >/dev/null 2>&1  || { echo "error: docker not installed"; exit 1; }
docker compose version >/dev/null 2>&1 || { echo "error: Docker Compose v2 plugin required (docker compose, not docker-compose)"; exit 1; }
command -v npm >/dev/null 2>&1 || { echo "error: npm not installed"; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "error: curl not installed"; exit 1; }

# Bootstrap root .env from .env.example if not present.
[[ -f .env ]] || cp .env.example .env

# Per-service .env files live inside submodule working trees.
# We do NOT create them automatically — print instructions and let the user opt in.
missing=0
for dir in posts-service SocialMediaUsersAPI software-architecture-message-service; do
  if [[ ! -f "$dir/.env" ]]; then
    echo "missing: $dir/.env  →  run:  cp $dir/.env.example $dir/.env"
    missing=1
  fi
done
if (( missing )); then
  echo
  echo "Create the missing .env file(s) above (fill in real secrets where needed), then rerun ./start.sh"
  exit 1
fi

# ── teardown trap ──────────────────────────────────────────────────────────
cleanup() {
  echo
  echo "Stopping backend services..."
  docker compose down
}
trap cleanup EXIT INT TERM

# ── backend ────────────────────────────────────────────────────────────────
echo "Building and starting backend services..."
echo "(First run downloads large images and may take several minutes.)"
echo
# --wait blocks until every service with a healthcheck reports healthy and
# every one-shot service (users-init, users-migrate) exits 0.
docker compose up --build --wait

# The three app services (posts, users, messages) have no healthchecks, so
# --wait only confirms their containers are running — not that their HTTP
# servers are ready. Poll each one until we get any HTTP response.
wait_for_http() {
  local name="$1" url="$2"
  printf "  %-14s" "$name"
  until curl -s --max-time 2 --output /dev/null "$url" 2>/dev/null; do
    printf "."
    sleep 2
  done
  echo " ready"
}

echo "Waiting for app servers to accept connections..."
wait_for_http "Posts API"    "http://localhost:8000/"
wait_for_http "Users API"    "http://localhost:8080/"
wait_for_http "Messages API" "http://localhost:3000/"

# ── frontend ───────────────────────────────────────────────────────────────
FRONT=software-architecture-project-frontend/instaclone

if [[ ! -d "$FRONT/node_modules" ]]; then
  echo "Installing frontend dependencies..."
  (cd "$FRONT" && npm install)
fi

echo
echo "All backend services are up:"
echo "  Posts API   →  http://localhost:8000"
echo "  Users API   →  http://localhost:8080"
echo "  Messages API→  http://localhost:3000"
echo
echo "Starting Vite dev server on http://localhost:5173"
echo "Press Ctrl-C to stop everything."
echo

# Do NOT use `exec` here — bash must stay in the process tree so the
# EXIT/INT/TERM trap above can fire and run `docker compose down`.
cd "$FRONT" && npm run dev
