#!/bin/bash
set -e

echo "==> TradingAgents API starting up"

# ── Helper: read a Docker secret file, return empty string if missing ─────────
read_secret() {
  local path="/run/secrets/$1"
  if [ -f "$path" ]; then
    # tr removes any trailing newline that editors sometimes add
    tr -d '[:space:]' < "$path"
  else
    echo ""
  fi
}

# Basic Auth is now Caddy's job (see deploy/Caddyfile) — it authenticates
# the request before it ever reaches this container, using a bcrypt hash
# generated once at secret-creation time (scripts/create_secrets.sh), not
# hashed here at every startup the way nginx's htpasswd used to be. Nothing
# for this entrypoint to do for auth anymore.

# ── 1. Ensure reports directory exists ───────────────────────────────────────
REPORTS_PATH="${REPORTS_PATH:-/data/reports}"
mkdir -p "$REPORTS_PATH"
echo "==> Reports directory: $REPORTS_PATH"

# ── 2. Build TradingAgents .env from Docker secrets ──────────────────────────
# TradingAgents reads its keys from a .env file in its own directory.
# We write it here at startup from secrets so keys never touch environment vars.
TA_ENV="/app/TradingAgents/.env"
echo "==> Writing TradingAgents .env from secrets"

# Truncate/create the file with tight permissions before writing
install -m 600 /dev/null "$TA_ENV"

write_secret_to_env() {
  local secret_name="$1"
  local env_key="$2"
  local value
  value="$(read_secret "$secret_name")"
  if [ -n "$value" ]; then
    echo "${env_key}=${value}" >> "$TA_ENV"
    echo "  [ok] $env_key"
  else
    echo "  [--] $env_key (not set)"
  fi
}

write_secret_to_env "anthropic_api_key"    "ANTHROPIC_API_KEY"
write_secret_to_env "openai_api_key"       "OPENAI_API_KEY"
write_secret_to_env "google_api_key"       "GOOGLE_API_KEY"
write_secret_to_env "finnhub_api_key"      "FINNHUB_API_KEY"
write_secret_to_env "reddit_client_id"     "REDDIT_CLIENT_ID"
write_secret_to_env "reddit_client_secret" "REDDIT_CLIENT_SECRET"

# Non-secret config value passed as env var
if [ -n "${REDDIT_USER_AGENT:-}" ]; then
  echo "REDDIT_USER_AGENT=${REDDIT_USER_AGENT}" >> "$TA_ENV"
fi

echo "==> TradingAgents .env written ($(wc -l < "$TA_ENV") keys)"

# ── 3. Start FastAPI (uvicorn) in foreground ─────────────────────────────────
# Bound to 0.0.0.0, not 127.0.0.1: Caddy now reaches this container over the
# Docker Compose network by service name (api:8000), not localhost — the two
# processes are no longer sharing one container's loopback interface.
echo "==> Starting FastAPI on port 8000"
cd /app
exec uvicorn api.main:app \
  --host 0.0.0.0 \
  --port 8000 \
  --workers 2 \
  --log-level info \
  --no-access-log
