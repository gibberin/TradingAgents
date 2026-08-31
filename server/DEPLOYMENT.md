# Deploying TradingAgents to Linode

Two containers behind Caddy, which handles TLS automatically via Let's
Encrypt: `caddy` (reverse proxy + TLS + Basic Auth) -> `api` (this FastAPI
app, which also serves the static viewer — see `api/main.py`'s `GET /`
route). No database, no message broker — just the one app service. See
`docker-compose.prod.yml`, `Dockerfile`, and `deploy/Caddyfile` for the
actual configs this document walks through.

`api` runs as a prebuilt image pulled from GHCR
(`ghcr.io/gibberin/tradingagents-api:release`) — nothing is compiled on
this server. CI (`.github/workflows/tradingagents-deploy.yml`) builds the
image exactly once per push to `release`, smoke-tests it, and only then
retags it `:release`; a deploy here is always a `docker compose pull` of
whatever CI just vetted, never a rebuild from source.

This repo (`TradingAgents`) is a fork of the upstream TauricResearch
project — it also holds the CLI/agent code the `server/` app wraps.
Everything below happens inside the `server/` subdirectory.

This mirrors WiseWire/`fenceaware-server`'s proven deployment pattern
(live on `fenceaware.com` since 2026-08-30) — see that project's
`DEPLOYMENT.md` if you want the pattern's original write-up. The one real
difference: no database/broker here, one app service instead of two, and
Basic Auth protects the whole UI (no per-user accounts) rather than
app-level JWT.

## 1. Provision the Linode instance

A Shared 4GB instance is the practical minimum — an analysis run spawns
an LLM-agent pipeline (several Claude/GPT calls per run) as a subprocess,
which is the real memory/CPU cost here, not the web serving itself.
Ubuntu 24.04 LTS is a safe default image.

Once created, note its public IPv4 address — you'll need it for DNS.

## 2. Point DNS at it

In your registrar/DNS provider for **focusario.com**, add:

| Host | Type | Value |
|---|---|---|
| `focusario.com` | A | your Linode's IP |
| `www.focusario.com` | CNAME | `focusario.com` |
| `api.focusario.com` | CNAME | `focusario.com` |

Since this app serves both the UI and the API from one origin (unlike
fenceaware-server, which was API-only with no frontend yet), the root
domain itself is what Caddy actually serves — `www` redirects to it (see
`deploy/Caddyfile`). `api.focusario.com` resolves but isn't wired to
anything in Caddy yet — reserved for a possible future dedicated
API-only entry point, not required for this deployment to work; see the
Caddyfile's comment on it. Give DNS a few minutes (up to the TTL) to
propagate before step 8 — Caddy's first request for a cert will fail if
the domain doesn't yet resolve to this server from the public internet.

## 3. Run the OS setup script

```bash
git clone https://github.com/gibberin/TradingAgents.git tradingagents
cd tradingagents
git checkout deploy-caddy   # <-- required until this merges to main; a plain
                            #     clone defaults to main, which still has the
                            #     retired nginx setup (no TLS, no domain, plain
                            #     http://<ip> — confirmed the hard way once already)
cd server
chmod +x scripts/deploy.sh
sudo ./scripts/deploy.sh
```

This installs Docker, mounts your Linode Block Storage volume at
`/mnt/reports` (you'll be prompted for the device path — set that volume
up in Linode Cloud Manager -> Volumes first if you haven't), and opens
the firewall (22, 80, 443). It does **not** build or start anything —
that's the rest of this document, since production now pulls a prebuilt
image rather than building on the box.

## 4. Configure `.env.production`

```bash
cp .env.production.example .env.production
```

Edit `.env.production` (never commit this file — it's gitignored):

- `DOMAIN` — `focusario.com`
- `ACME_EMAIL` — a real address; Let's Encrypt uses this only to warn you
  if a renewal is about to fail
- `BASIC_AUTH_USER` — the web login username
- `BASIC_AUTH_HASH` — **not** a plaintext password. Caddy's `basicauth`
  directive needs a bcrypt hash, generated once, up front:
  ```bash
  docker run --rm caddy:2-alpine caddy hash-password --plaintext 'your-real-password'
  ```
  Paste the full `$2a$...` output as `BASIC_AUTH_HASH`. The plaintext
  password is never written to disk anywhere — only the hash is, both
  here and inside the Caddyfile substitution at runtime.
- `REPORTS_HOST_PATH` — `/mnt/reports` (or wherever step 3 mounted your
  volume, if different)

## 5. Configure the app's own secrets

```bash
chmod +x scripts/create_secrets.sh
./scripts/create_secrets.sh
```

Prompts interactively for the LLM provider key(s) and FinnHub key, writes
each as its own file under `./secrets/` (chmod 600). See
`scripts/create_secrets.sh`'s header for why Basic Auth isn't part of
this script anymore — it moved to `.env.production` in step 4, since
Caddy needs it as an env-var substitution, not a file a container reads
at startup.

## 6. Log in to GHCR

`api` is pulled as a prebuilt image from `ghcr.io/gibberin/tradingagents-*`
— this repo's GitHub Container Registry package. Unless you've made it
public, pulling requires authentication, and that's a one-time setup on
this server (Docker caches the credential in `~/.docker/config.json`; you
won't repeat this on every deploy):

1. On GitHub: **your avatar -> Settings -> Developer settings -> Personal
   access tokens -> Tokens (classic)** -> Generate new token, scope
   `read:packages` only. This is a *separate* token from the deploy SSH
   keypair below — it only ever grants pulling images, nothing else.
2. On the server:
   ```bash
   echo '<paste the token>' | docker login ghcr.io -u <your-github-username> --password-stdin
   ```

If this step is skipped, `docker compose pull` in step 7 (and every
redeploy after) fails with `unauthorized` or `denied` rather than
anything more obviously about missing credentials.

## 7. First deploy

```bash
docker compose --env-file .env.production -f docker-compose.prod.yml pull
docker compose --env-file .env.production -f docker-compose.prod.yml up -d
```

`pull` fetches the `api` image CI already built and smoke-tested (see the
top of this document) — nothing is compiled on this box. `up -d` starts
`api`, then `caddy`, which requests a Let's Encrypt cert for `DOMAIN` on
first request.

Watch it come up:

```bash
docker compose -f docker-compose.prod.yml logs -f
```

You're looking for `Starting FastAPI on port 8000` from `api` and no TLS
errors from `caddy` (a successful cert issuance logs something like
`certificate obtained successfully`). Then hit `https://focusario.com` —
the browser should prompt for the Basic Auth credentials from step 4,
show a valid real certificate with no warnings, and load the viewer.

## Redeploying after a change

```bash
git pull origin release
docker compose --env-file .env.production -f docker-compose.prod.yml pull
docker compose --env-file .env.production -f docker-compose.prod.yml up -d
```

`git pull` is still needed — `docker-compose.prod.yml` and
`deploy/Caddyfile` are config, not application code, and still live on
this box as bind-mounted files. But the `api` *application image* itself
is never rebuilt here — `pull` fetches whatever CI most recently
smoke-tested and tagged `:release`. Caddy's certs persist across this
(named volume, untouched by either command). This is also exactly what
CI runs for you automatically once continuous deployment is set up — see
below.

**Rolling back:** GHCR keeps every sha-tagged image CI has ever pushed
(Package settings on github.com control retention/cleanup). To roll
back, point `:release` at an older sha and redeploy:

```bash
docker buildx imagetools create -t ghcr.io/gibberin/tradingagents-api:release ghcr.io/gibberin/tradingagents-api:<old-sha>
```
then `pull` + `up -d` as above on the server. This needs `docker login
ghcr.io` with *write* access (your own account's token, not the
read-only one from step 6), so run the `imagetools` command from your own
machine or another box you trust with that, not the production server.

## Continuous deployment (GitHub Actions)

`.github/workflows/tradingagents-deploy.yml` triggers on every push to
`release` that touches `server/**`:

1. **`build`** — builds the `api` image once, tags it with the commit
   SHA, and pushes it to GHCR (`ghcr.io/gibberin/tradingagents-api`).
2. **`smoke-test`** — pulls that exact sha-tagged image (no rebuild) and
   boots it alone (no Caddy — TLS isn't testable here; no real LLM keys
   either), then hits `/health`, `/reports`, and `/` and checks each
   responds sanely (`tradingagents-smoke-test.sh`). It deliberately never
   runs a real analysis — that costs real API money and isn't needed to
   prove the image boots correctly.
3. **`deploy`** — only if that passes, retags that same sha image
   `:release` on GHCR (no rebuild, no re-test), then SSHes to the Linode
   box, whose forced command pulls `:release` and starts it.

The image that gets tested and the image that runs in production are the
same bytes end to end — a broken commit on `release` never reaches
production, and neither does an untested one; it just fails the Actions
run.

**Status: not yet set up.** The steps below are the walkthrough for
doing so, once there's a real first deploy ready to ship (this mirrors
exactly how fenceaware-server's equivalent setup was done — see that
project's own history if useful as a reference).

1. **Create the `release` branch** (`git checkout -b release` from
   `main`, or wherever the revision you want to ship lives, then
   `git push -u origin release`).
2. **Generate a dedicated deploy keypair** — don't reuse a key from
   another project (WiseWire's `fenceaware_deploy` key, for instance,
   should never touch this server):
   ```bash
   ssh-keygen -t ed25519 -f ~/.ssh/tradingagents_deploy -C "github-actions-deploy@tradingagents" -N ""
   ```
   On Windows PowerShell, `-N ""` gets silently stripped and ssh-keygen
   errors with `option requires an argument -- N` — drop `-N` and press
   Enter twice at the passphrase prompts instead (empty passphrase is
   correct here; a passphrase-protected key can't be used
   non-interactively by the SSH action in CI).

   Keep the private key somewhere permanent on your own machine (not a
   session scratchpad dir) — you'll paste it into a GitHub secret and
   need it again if that secret is ever lost. When pasting it into the
   `DEPLOY_SSH_KEY` secret (step 5), don't select-and-copy it out of a
   terminal by hand — an easy way to drop a line break and produce a key
   GitHub's SSH library rejects with `ssh: no key found`. On Windows,
   pipe it to the clipboard instead:
   ```powershell
   Get-Content -Raw $HOME\.ssh\tradingagents_deploy | Set-Clipboard
   ```
3. **Add the public half to the server**, restricted so it can *only*
   ever run the deploy command — even if the private key/GitHub secret
   ever leaked, it can't open a general shell on your box. Append this as
   its own line in the deploy user's `~/.ssh/authorized_keys` (the same
   account you already SSH in as to run manual deploys — it already has
   `docker` group membership, the repo cloned, and — per step 6 above —
   is already logged in to GHCR):
   ```
   command="cd ~/tradingagents/server && git pull origin release && docker compose --env-file .env.production -f docker-compose.prod.yml pull && docker compose --env-file .env.production -f docker-compose.prod.yml up -d",no-pty,no-port-forwarding,no-X11-forwarding,no-agent-forwarding <paste ~/.ssh/tradingagents_deploy.pub here>
   ```
   Adjust `~/tradingagents` if your clone lives somewhere else. The
   `command=` prefix means the server ignores whatever command this
   key's client actually sends and always runs this one instead — that's
   deliberate, not a placeholder to fill in.
4. **Create a GitHub Environment named `production`** (this repo ->
   Settings -> Environments -> New environment — a different page from
   Settings -> Secrets). Under **Deployment branches and tags**, restrict
   it to the `release` branch only. This is what actually scopes the
   four secrets below to `release` alone at the platform level, not just
   by convention — `tradingagents-deploy.yml`'s `environment: production`
   line is what ties the job to this environment and its branch
   restriction.
5. **Add four secrets to that environment** (on the same `production`
   environment's page, not the repo-level Secrets page):
   - `DEPLOY_HOST` — `focusario.com` (or the Linode's IP)
   - `DEPLOY_USER` — the SSH username from step 3
   - `DEPLOY_PORT` — `22`, unless you've moved SSH to a different port
   - `DEPLOY_SSH_KEY` — the private half of the keypair from step 2,
     pasted byte-exact
6. **Allow GITHUB_TOKEN to push packages**: this repo -> Settings ->
   Actions -> General -> **Workflow permissions** -> "Read and write
   permissions". The `build`/`deploy` jobs set `permissions: packages:
   write` in the workflow itself, but that can only *narrow* what this
   repo-level setting already allows, never grant more — left on the
   default, the push to GHCR fails with a 403 no matter what the
   workflow file says. No PAT needed for this part; `GITHUB_TOKEN` is
   issued automatically per run.
7. Complete step 6 in the walkthrough above (`docker login ghcr.io` on
   the server) if you haven't already — the deploy job's `pull` will
   fail without it.
8. Push to `release` (or re-run the workflow from the Actions tab) and
   watch it in GitHub's Actions tab — `build`, `smoke-test`, then
   `deploy`, all green.

## Backups

Not automated yet. Reports (`/mnt/reports`) are the only real state this
app holds — everything else is stateless (Caddy's certs are cheap to
re-issue, secrets are recreatable from your own records). Worth a
periodic `rsync`/`tar` of `/mnt/reports` off-server before it's holding
data you'd be sad to lose, or rely on Linode Block Storage's own
snapshot/backup offering directly on the volume.

## Known gaps worth knowing about before real users show up

- **Shared Basic Auth credential.** Every user of this deployment shares
  one username/password — no per-user accounts, no way to revoke one
  person's access without rotating it for everyone. Fine for a small
  trusted group (you, your daughter, one more user); revisit if this
  grows further.
- **No structured logging/error tracking.** `docker compose logs` is
  your only window into a production error right now.
- **No automated backups** — see above.
