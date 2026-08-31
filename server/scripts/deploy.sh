#!/bin/bash
# =============================================================================
# deploy.sh — TradingAgents Viewer: Linode VPS setup script
#
# Run this on a fresh Linode Debian 12 / Ubuntu 24.04 VM as root.
# Usage:
#   chmod +x deploy.sh
#   sudo ./deploy.sh
#
# What it does:
#   1. Updates the system
#   2. Installs Docker + Docker Compose
#   3. Mounts your Linode Block Storage volume at /mnt/reports
#   4. Prompts you to configure .env
#   5. Builds and starts the container
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERR]${NC}  $*"; exit 1; }

# ── 0. Must be root ───────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && error "Please run as root: sudo ./deploy.sh"

# ── 1. Detect OS ─────────────────────────────────────────────────────────────
. /etc/os-release
info "Detected OS: $PRETTY_NAME"

# ── 2. System update ──────────────────────────────────────────────────────────
info "Updating system packages…"
apt-get update -qq && apt-get upgrade -y -qq
success "System updated"

# ── 3. Install Docker ─────────────────────────────────────────────────────────
if command -v docker &>/dev/null; then
  success "Docker already installed: $(docker --version)"
else
  info "Installing Docker…"
  apt-get install -y -qq ca-certificates curl gnupg lsb-release

  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/$(. /etc/os-release && echo "$ID")/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/$(. /etc/os-release && echo "$ID") \
    $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list

  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
  systemctl enable --now docker
  success "Docker installed: $(docker --version)"
fi

# ── 4. Block Storage volume ────────────────────────────────────────────────────
MOUNT_POINT="/mnt/reports"
info "Setting up Block Storage volume at $MOUNT_POINT"
echo ""
echo "  You need a Linode Block Storage volume attached to this VM."
echo "  Steps if you haven't done this yet:"
echo "    1. In Linode Cloud Manager → Volumes → Create Volume"
echo "    2. Attach it to this Linode instance"
echo "    3. Note the device path (usually /dev/sdc or /dev/disk/by-id/scsi-...)"
echo ""

# List available block devices
info "Available block devices:"
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT | grep -v loop || true
echo ""

read -rp "Enter the device path for your Linode volume (e.g. /dev/sdc): " VOLUME_DEV

if [[ -z "$VOLUME_DEV" ]]; then
  warn "No device entered — skipping volume mount. Using local directory $MOUNT_POINT instead."
  mkdir -p "$MOUNT_POINT"
else
  # Format if no filesystem detected
  FSTYPE=$(lsblk -no FSTYPE "$VOLUME_DEV" 2>/dev/null || echo "")
  if [[ -z "$FSTYPE" ]]; then
    warn "No filesystem detected on $VOLUME_DEV — formatting as ext4…"
    read -rp "  Confirm format $VOLUME_DEV? This will ERASE the volume. (yes/no): " CONFIRM
    [[ "$CONFIRM" != "yes" ]] && error "Aborted."
    mkfs.ext4 -F "$VOLUME_DEV"
    success "Formatted $VOLUME_DEV as ext4"
  else
    success "Filesystem $FSTYPE already on $VOLUME_DEV"
  fi

  mkdir -p "$MOUNT_POINT"

  # Mount now
  if mountpoint -q "$MOUNT_POINT"; then
    success "$MOUNT_POINT already mounted"
  else
    mount "$VOLUME_DEV" "$MOUNT_POINT"
    success "Mounted $VOLUME_DEV → $MOUNT_POINT"
  fi

  # Persist in fstab
  VOLUME_UUID=$(blkid -s UUID -o value "$VOLUME_DEV")
  if ! grep -q "$VOLUME_UUID" /etc/fstab; then
    echo "UUID=$VOLUME_UUID  $MOUNT_POINT  ext4  defaults,nofail  0  2" >> /etc/fstab
    success "Added $MOUNT_POINT to /etc/fstab (persists across reboots)"
  else
    success "Already in /etc/fstab"
  fi
fi

# ── 5. Configure .env (non-sensitive config only) ─────────────────────────────
DEPLOY_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="$DEPLOY_DIR/.env"

if [[ ! -f "$ENV_FILE" ]]; then
  cp "$DEPLOY_DIR/.env.example" "$ENV_FILE"
  info "Created .env from template"
fi

# Auto-set REPORTS_HOST_PATH to the mount point we configured above
sed -i "s|REPORTS_HOST_PATH=.*|REPORTS_HOST_PATH=$MOUNT_POINT|" "$ENV_FILE"
success "Set REPORTS_HOST_PATH=$MOUNT_POINT in .env"

# ── 6. Set up Docker secrets ──────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  API keys and passwords are stored as Docker secrets."
echo "  They live in ./secrets/ as individual files (chmod 600)."
echo "  They are NEVER written to environment variables."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
chmod +x "$DEPLOY_DIR/scripts/create_secrets.sh"
"$DEPLOY_DIR/scripts/create_secrets.sh"

# ── 7. Firewall ───────────────────────────────────────────────────────────────
info "Configuring firewall (ufw)…"
if command -v ufw &>/dev/null; then
  ufw allow 22/tcp  comment "SSH"  2>/dev/null || true
  ufw allow 80/tcp  comment "HTTP" 2>/dev/null || true
  ufw --force enable 2>/dev/null || true
  success "Firewall: SSH(22) and HTTP(80) open"
else
  warn "ufw not found — skipping firewall config"
fi

# ── 8. Build and start ────────────────────────────────────────────────────────
cd "$DEPLOY_DIR"

info "Building Docker image (this takes a few minutes on first run)…"
docker compose build --no-cache

info "Starting container…"
docker compose up -d

success "Container started!"

# ── 9. Summary ────────────────────────────────────────────────────────────────
LINODE_IP=$(curl -s http://169.254.169.254/v1/instance/network_interfaces 2>/dev/null \
  | grep -oP '"ip_address":"\K[^"]+' | head -1 \
  || hostname -I | awk '{print $1}')

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "  ${GREEN}TradingAgents is running!${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  URL:      http://${LINODE_IP}"
echo "  Username: $(grep BASIC_AUTH_USER $ENV_FILE | cut -d= -f2)"
echo "  Password: (as set in .env)"
echo ""
echo "  Reports stored at: $MOUNT_POINT"
echo ""
echo "  Useful commands:"
echo "    docker compose logs -f        # live logs"
echo "    docker compose restart        # restart"
echo "    docker compose down           # stop"
echo "    docker compose pull && docker compose up -d  # update"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
