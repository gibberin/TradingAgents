# TradingAgents Viewer — Linode Deployment

A self-hosted web interface for running and viewing TradingAgents analyses.

**For the full deployment walkthrough — provisioning, DNS, secrets, first
deploy, and CI/CD setup — see [DEPLOYMENT.md](./DEPLOYMENT.md).** This
file is a quick architecture/usage overview.

## Architecture

```
Browser → Caddy (ports 80/443, TLS via Let's Encrypt, Basic Auth)
              └── everything → FastAPI (api container, port 8000)
                                  ├── GET  /                serves the viewer (SPA)
                                  ├── GET  /reports         list reports
                                  ├── GET  /reports/{id}    load report files
                                  ├── POST /run             start analysis
                                  └── GET  /run/{id}/stream SSE log stream

Persistent storage: Linode Block Storage volume → /data/reports (inside container)
```

Two containers (`caddy`, `api`) — nginx was retired; Caddy is now the only
edge process (TLS + Basic Auth + reverse proxy, including the SSE
run-progress stream, natively), and FastAPI serves the static viewer
itself rather than a separate process doing it. `api` runs as a prebuilt
image pulled from GHCR, built and smoke-tested by CI on every push to
`release` — see DEPLOYMENT.md's "Continuous deployment" section.

## Daily Usage

### Access the interface

Open `https://focusario.com` in your browser. Enter your username and
password when prompted (Basic Auth, from `.env.production`).

### Run an analysis

1. Click **Run Analysis** in the top nav
2. Enter a ticker symbol (e.g. `ALAB`) and select a date
3. Choose a Claude model
4. Click **▶ Start Analysis**

The terminal panel streams live output as each agent runs. Progress stages
highlight as the pipeline advances (Analysts → Research → Manager → Trader
→ Risk → Decision).

When complete, the report automatically appears in the **Reports** tab.

### View reports

Click **Reports** in the top nav. Reports are listed newest-first with
ticker, date, and verdict. Click any report to open it; use the tab bar to
navigate between sections.

---

## Maintenance

```bash
# View live logs
docker compose -f docker-compose.prod.yml logs -f

# Restart
docker compose -f docker-compose.prod.yml restart

# Stop everything
docker compose -f docker-compose.prod.yml down

# Redeploy after CI pushes a new :release image
docker compose --env-file .env.production -f docker-compose.prod.yml pull
docker compose --env-file .env.production -f docker-compose.prod.yml up -d

# Check disk usage of reports volume
du -sh /mnt/reports/*
```

See DEPLOYMENT.md for rollback, backups, and the full CI/CD setup.

---

## File Structure

```
server/
├── Dockerfile                 # api image (FastAPI only — no nginx)
├── docker-compose.yml         # local dev (build from source, no Caddy/TLS)
├── docker-compose.prod.yml    # production (pulls GHCR image, behind Caddy)
├── docker-compose.ci.yml      # CI smoke-test stack
├── .env.example                # local dev config template
├── .env.production.example    # production config template (domain, ACME, Basic Auth)
├── api/
│   ├── main.py                # FastAPI backend (also serves the viewer)
│   └── requirements.txt
├── deploy/
│   └── Caddyfile               # TLS + Basic Auth + reverse proxy
├── viewer/
│   └── index.html              # single-page web app
└── scripts/
    ├── deploy.sh                # Linode OS-level setup (Docker, volume, firewall)
    ├── create_secrets.sh        # LLM/data-vendor API keys → ./secrets/
    └── entrypoint.sh             # container startup script
```

---

## Security Notes

- The entire interface is protected by HTTP Basic Auth (Caddy)
- TLS is automatic and auto-renewing via Caddy/Let's Encrypt — no certbot,
  no manual renewal step
- API keys are passed via Docker secrets and written to the container's
  `.env` at startup; they are never served to the browser
- The reports path is validated server-side to prevent path traversal
- Basic Auth is shared across all users of this deployment (no per-user
  accounts) — see DEPLOYMENT.md's "Known gaps" section
