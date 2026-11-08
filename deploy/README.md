# Deploy OpenReply to a VPS with GitHub Actions

Every push to `main` builds the image on GitHub, pushes it to GitHub Container
Registry (free), SSHes into your VPS and restarts the stack. Caddy gets a free
HTTPS certificate automatically. The VPS never builds anything, so 1–2 GB RAM is
enough.

Cost: GitHub Actions and GHCR are free for this use (public repo). Resend free
tier = 3,000 emails/month, and this app only sends sign-in links. You pay only
for the VPS.

## 1. Server (once, over SSH, as root)

```sh
# Docker + Compose plugin (skip if `docker compose version` already works)
curl -fsSL https://get.docker.com | sh

# Deploy user that can run Docker
adduser --disabled-password --gecos "" deploy
usermod -aG docker deploy

# Under 2 GB RAM: add 2 GB swap so Postgres + Node never get OOM-killed
fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab

# If ufw is on, open web ports (SSH must stay open too)
ufw allow 22/tcp && ufw allow 80/tcp && ufw allow 443/tcp
```

## 2. SSH key for GitHub Actions (on your own computer)

```sh
ssh-keygen -t ed25519 -f openreply_deploy -N "" -C "github-actions-openreply"
ssh-copy-id -i openreply_deploy.pub deploy@YOUR_SERVER_IP
ssh-keyscan -H YOUR_SERVER_IP      # copy the output into SSH_KNOWN_HOSTS
```

## 3. DNS

Create an **A record** for your subdomain (e.g. `reply.yourdomain.com`) pointing at
the server IP **before** the first deploy, or Caddy cannot get a certificate.

## 4. GitHub settings (your fork → Settings → Secrets and variables → Actions)

**Secrets**

| Name | Value |
|---|---|
| `SSH_HOST` | server IP or host name |
| `SSH_USER` | `deploy` |
| `SSH_PRIVATE_KEY` | full contents of `openreply_deploy` (private key) |
| `SSH_KNOWN_HOSTS` | output of `ssh-keyscan` above (recommended) |
| `RESEND_API_KEY` | `re_...` |
| `INSTAGRAM_APP_ID` | from your Meta app |
| `INSTAGRAM_APP_SECRET` | from your Meta app |
| `FACEBOOK_APP_SECRET` | from your Meta app |
| `WEBHOOK_VERIFY_TOKEN` | any random string; paste the same into Meta's webhook config |

**Variables**

| Name | Value |
|---|---|
| `DOMAIN` | `reply.yourdomain.com` (no `https://`) |
| `EMAIL_FROM` | `OpenReply <login@yourdomain.com>` (domain verified in Resend) |
| `ALLOWED_EMAILS` | your email(s), comma separated. Required: without it anyone can sign up on your server |
| `SSH_PORT` | only if SSH is not on 22 |
| `DEPLOY_ENABLED` | `true` (set this last) |

No value may contain a single quote `'`.

Forks have Actions disabled by default: open the **Actions** tab and enable workflows.

## 5. Deploy

Actions → **Deploy to VPS** → Run workflow (or push to `main`). The last step
checks `https://DOMAIN/api/health` and fails loudly if it never turns healthy.

## 6. Meta app

- OAuth redirect URI: `https://DOMAIN/api/instagram/callback`
- Webhook callback URL: `https://DOMAIN/api/webhook`, verify token = `WEBHOOK_VERIFY_TOKEN`

Full Meta steps: `docs/setup.md`.

## Generated secrets: back them up

The first deploy creates `~/openreply/secrets.env` on the server
(`POSTGRES_PASSWORD`, `NEXTAUTH_SECRET`, `CRON_SECRET`, `ENCRYPTION_KEY`). It is
never overwritten. Losing `ENCRYPTION_KEY` makes every connected Instagram
account unreadable. Copy it somewhere safe:

```sh
scp deploy@YOUR_SERVER_IP:openreply/secrets.env ./openreply-secrets.env
```

## Operating

```sh
cd ~/openreply
docker compose -f docker-compose.prod.yml --env-file .env ps
docker compose -f docker-compose.prod.yml --env-file .env logs -f web worker
# DB backup
docker compose -f docker-compose.prod.yml --env-file .env exec -T postgres pg_dump -U openreply openreply | gzip > backup-$(date +%F).sql.gz
```
