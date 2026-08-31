# TradingAgents Viewer — Linode Deployment

A self-hosted web interface for running and viewing TradingAgents analyses, deployed as a Docker container on a Linode VPS with Block Storage persistence.

## Architecture

```
Browser → Nginx (port 80, Basic Auth)
              ├── /          → Static viewer (HTML/JS)
              └── /api/      → FastAPI (Python)
                                  ├── GET  /reports         list reports
                                  ├── GET  /reports/{id}    load report files
                                  ├── POST /run             start analysis
                                  └── GET  /run/{id}/stream SSE log stream

Persistent storage: Linode Block Storage volume → /data/reports (inside container)
```

## Prerequisites

| What | Where |
|------|-------|
| Linode account | cloud.linode.com |
| Linode VM | 4GB Shared (Linode 4) recommended minimum |
| Linode Block Storage volume | 20GB minimum, attach to the VM |
| Anthropic API key | console.anthropic.com |
| FinnHub API key | finnhub.io (free tier) |

---

## Step-by-step Deployment

### 1. Create a Linode VM

1. Log in to [Linode Cloud Manager](https://cloud.linode.com)
2. **Create → Linode**
   - Image: **Debian 12** or **Ubuntu 24.04 LTS**
   - Region: closest to you
   - Plan: **Linode 4GB Shared** ($24/mo) — minimum for running LLM analyses
   - Set a root password and optionally add your SSH key
3. Note the public IP address

### 2. Create and attach a Block Storage volume

1. In Cloud Manager → **Volumes → Create Volume**
   - Label: `tradingagents-reports`
   - Size: 20GB (increase later as needed)
   - Region: **same as your VM**
2. Click **Attach to Linode** and select your VM
3. Note the device path shown (usually `/dev/sdc`)

### 3. Upload this project to your VM

```bash
# From your local machine
scp -r tradingagents-deploy/ root@YOUR_LINODE_IP:~/tradingagents-deploy/
```

Or clone/copy however you prefer (git, rsync, etc.).

### 4. Run the deploy script

```bash
ssh root@YOUR_LINODE_IP
cd ~/tradingagents-deploy
chmod +x scripts/deploy.sh scripts/entrypoint.sh
sudo ./scripts/deploy.sh
```

The script will:
- Update the system and install Docker
- Format and mount your Block Storage volume at `/mnt/reports`
- Persist the mount in `/etc/fstab`
- Prompt you to edit `.env` with your API keys
- Build the Docker image and start the container
- Open port 80 in the firewall

### 5. Configure secrets

The deploy script automatically runs `scripts/create_secrets.sh`, which prompts you interactively for each key and writes them as individual files under `./secrets/` (chmod 600, never in environment variables).

Secrets created:

| File | What it holds |
|------|--------------|
| `secrets/basic_auth_user` | Web UI login username |
| `secrets/basic_auth_password` | Web UI login password |
| `secrets/anthropic_api_key` | Anthropic API key |
| `secrets/finnhub_api_key` | FinnHub market data key |
| `secrets/openai_api_key` | OpenAI key (optional) |
| `secrets/google_api_key` | Google AI key (optional) |
| `secrets/reddit_client_id` | Reddit client ID (optional) |
| `secrets/reddit_client_secret` | Reddit secret (optional) |

The `./secrets/` directory is in `.gitignore` — it will never be accidentally committed.

To update a single secret later without a full redeploy:
```bash
printf 'new-key-value' > secrets/anthropic_api_key
chmod 600 secrets/anthropic_api_key
docker compose restart
```

---

## Daily Usage

### Access the interface

Open `http://YOUR_LINODE_IP` in your browser. Enter your username and password when prompted.

### Run an analysis

1. Click **Run Analysis** in the top nav
2. Enter a ticker symbol (e.g. `ALAB`) and select a date
3. Choose a Claude model
4. Click **▶ Start Analysis**

The terminal panel streams live output as each agent runs. Progress stages highlight as the pipeline advances (Analysts → Research → Manager → Trader → Risk → Decision).

When complete, the report automatically appears in the **Reports** tab.

### View reports

Click **Reports** in the top nav. Reports are listed newest-first with ticker, date, and verdict. Click any report to open it; use the tab bar to navigate between sections.

---

## Maintenance

```bash
# View live logs
docker compose logs -f

# Restart the container
docker compose restart

# Stop everything
docker compose down

# Rebuild after code changes
docker compose build && docker compose up -d

# Check disk usage of reports volume
du -sh /mnt/reports/*
```

## Updating TradingAgents

TradingAgents is cloned from GitHub during the Docker build. To update to the latest version:

```bash
docker compose build --no-cache
docker compose up -d
```

---

## File Structure

```
tradingagents-deploy/
├── Dockerfile                # Container definition
├── docker-compose.yml        # Service config + volume mapping
├── .env.example              # Template — copy to .env
├── api/
│   ├── main.py               # FastAPI backend
│   └── requirements.txt
├── nginx/
│   └── nginx.conf            # Reverse proxy + Basic Auth
├── viewer/
│   └── index.html            # Single-page web app
└── scripts/
    ├── deploy.sh             # Linode setup script
    └── entrypoint.sh         # Container startup script
```

---

## Security Notes

- The entire interface is protected by HTTP Basic Auth (Nginx)
- API keys are passed via environment variables and written to the container's `.env` at startup; they are never served to the browser
- The reports path is validated server-side to prevent path traversal
- For production use, consider adding TLS via Let's Encrypt (Certbot) — the Nginx config has port 443 reserved for this

## Adding TLS (optional, recommended)

```bash
# On the Linode VM
apt install certbot python3-certbot-nginx
certbot --nginx -d your-domain.com
```

Then update `nginx.conf` to redirect HTTP → HTTPS.
