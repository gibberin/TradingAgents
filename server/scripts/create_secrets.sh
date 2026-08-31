#!/bin/bash
# =============================================================================
# create_secrets.sh — Interactively populate ./secrets/ for Docker secrets
#
# Run this once on your Linode VM before `docker compose up`.
# Each secret is written as a single-line file with chmod 600.
# The ./secrets/ directory itself is chmod 700.
#
# Usage:
#   chmod +x scripts/create_secrets.sh
#   ./scripts/create_secrets.sh
# =============================================================================

set -euo pipefail

SECRETS_DIR="$(cd "$(dirname "$0")/.." && pwd)/secrets"
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

info()    { echo -e "${CYAN}[info]${NC} $*"; }
success() { echo -e "${GREEN}[ok]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[warn]${NC} $*"; }

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  TradingAgents — Secrets Setup"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  This script writes your API keys and passwords into"
echo "  individual files under ./secrets/."
echo ""
echo "  Each file is chmod 600 (owner read/write only)."
echo "  The directory is chmod 700."
echo "  None of these values will appear in environment variables."
echo ""
echo "  Press Enter to skip any optional secret."
echo ""

# ── Create directory ──────────────────────────────────────────────────────────
mkdir -p "$SECRETS_DIR"
chmod 700 "$SECRETS_DIR"

# ── Helper: prompt and write a secret ────────────────────────────────────────
# Usage: write_secret <filename> <prompt> <required|optional> [default]
write_secret() {
  local name="$1"
  local prompt="$2"
  local required="$3"
  local default="${4:-}"
  local path="$SECRETS_DIR/$name"
  local value=""

  # Show existing value hint if file already exists
  if [ -f "$path" ]; then
    local existing
    existing="$(cat "$path" | tr -d '[:space:]')"
    local hint="${existing:0:6}…${existing: -4}"
    echo -e "  ${CYAN}$prompt${NC} [current: $hint]"
    read -rp "  New value (Enter to keep current): " value
    if [ -z "$value" ]; then
      success "Keeping existing $name"
      return
    fi
  else
    if [ "$required" = "required" ]; then
      echo -e "  ${CYAN}$prompt${NC} ${YELLOW}(required)${NC}"
    else
      echo -e "  ${CYAN}$prompt${NC} (optional, Enter to skip)"
    fi
    read -rp "  Value: " value
  fi

  if [ -z "$value" ]; then
    if [ "$required" = "required" ]; then
      warn "$name is required — leaving empty, but startup will warn"
      # Write an empty file so Docker doesn't error on missing secret
      install -m 600 /dev/null "$path"
    else
      info "Skipping $name"
      # Write empty file — entrypoint.sh handles missing gracefully
      install -m 600 /dev/null "$path"
    fi
  else
    # Write without trailing newline
    printf '%s' "$value" > "$path"
    chmod 600 "$path"
    success "Written $name"
  fi
  echo ""
}

# ── Auth ──────────────────────────────────────────────────────────────────────
echo "── Web Interface Authentication ─────────────────────────"
write_secret "basic_auth_user"     "Username for web login" "required"
write_secret "basic_auth_password" "Password for web login" "required"

# ── LLM providers ─────────────────────────────────────────────────────────────
echo "── LLM Provider (at least one required) ─────────────────"
write_secret "anthropic_api_key" "Anthropic API key (sk-ant-...)" "optional"
write_secret "openai_api_key"    "OpenAI API key (sk-...)"        "optional"
write_secret "google_api_key"    "Google AI API key"              "optional"

# ── Financial data ────────────────────────────────────────────────────────────
echo "── Financial Data ───────────────────────────────────────"
write_secret "finnhub_api_key" "FinnHub API key (finnhub.io)" "required"

# ── Reddit ────────────────────────────────────────────────────────────────────
echo "── Reddit (optional — sentiment analysis) ───────────────"
write_secret "reddit_client_id"     "Reddit client ID"     "optional"
write_secret "reddit_client_secret" "Reddit client secret" "optional"

# ── Summary ───────────────────────────────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${GREEN}  Secrets written to: $SECRETS_DIR${NC}"
echo ""
echo "  Files created:"
for f in "$SECRETS_DIR"/*; do
  size=$(wc -c < "$f")
  if [ "$size" -gt 0 ]; then
    echo -e "  ${GREEN}✓${NC}  $(basename "$f")  (${size} bytes)"
  else
    echo -e "  ${YELLOW}–${NC}  $(basename "$f")  (empty / skipped)"
  fi
done
echo ""
echo "  To update a single secret later:"
echo "    printf 'new-value' > $SECRETS_DIR/<name>"
echo "    chmod 600 $SECRETS_DIR/<name>"
echo "    docker compose restart"
echo ""
echo "  Next step:"
echo "    docker compose up -d"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
