FROM python:3.13-slim

# ── System deps ──────────────────────────────────────────────────────────────
# nginx/apache2-utils dropped: Caddy is now the only edge proxy (TLS + Basic
# Auth + reverse proxy), running as its own container — see
# docker-compose.prod.yml and deploy/Caddyfile. This image is FastAPI only.
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    curl \
    gcc \
    && rm -rf /var/lib/apt/lists/*

# ── Python deps ──────────────────────────────────────────────────────────────
WORKDIR /app
COPY api/requirements.txt /app/api/requirements.txt
RUN pip install --no-cache-dir -r /app/api/requirements.txt

# ── TradingAgents ─────────────────────────────────────────────────────────────
# Clone and install TradingAgents from the official repo
RUN git clone https://github.com/TauricResearch/TradingAgents.git /app/TradingAgents
RUN pip install --no-cache-dir -e /app/TradingAgents

# ── Copy application files ────────────────────────────────────────────────────
COPY api/          /app/api/
COPY viewer/       /app/viewer/
COPY scripts/      /app/scripts/

RUN chmod +x /app/scripts/*.sh

# ── Reports volume mount point ────────────────────────────────────────────────
RUN mkdir -p /data/reports

# ── Entrypoint ────────────────────────────────────────────────────────────────
COPY scripts/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 8000

ENTRYPOINT ["/entrypoint.sh"]
