#!/usr/bin/env bash
# ╔══════════════════════════════════════╗
# ║   Peach - iOS Backup for Linux       ║
# ║   Installer                          ║
# ╚══════════════════════════════════════╝
set -euo pipefail

PEACH_DIR="/opt/peach"
CONFIG_DIR="/etc/peach"
SERVICE_FILE="/etc/systemd/system/peach.service"
UDEV_RULE="/etc/udev/rules.d/99-peach-ios.rules"
PORT=5173
GITHUB_REPO="jbkr43/peach"
GITHUB_API="https://api.github.com/repos/${GITHUB_REPO}/releases/latest"

# ── Colors ───────────────────────────────────────────────────────────────────
PEACH='\033[38;5;209m'
GREEN='\033[0;32m'
RED='\033[0;31m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'

log()    { echo -e "${PEACH}▸${NC} $*"; }
ok()     { echo -e "${GREEN}✓${NC} $*"; }
err()    { echo -e "${RED}✗${NC} $*"; exit 1; }
header() { echo -e "\n${BOLD}$*${NC}"; }

# ── Banner ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${PEACH}${BOLD}"
echo "   🍑  Peach"
echo -e "${NC}${DIM}   iOS Backup Manager for Linux${NC}"
echo ""

# ── Root check ────────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  err "Please run as root: sudo bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/${GITHUB_REPO}/main/install.sh)\""
fi

# Use the invoking user's home dir, not /root
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)

# ── Check tools ───────────────────────────────────────────────────────────────
header "Checking tools..."
command -v curl &>/dev/null || err "'curl' is required but not installed."
ok "curl available"

# ── Detect distro ─────────────────────────────────────────────────────────────
header "Detecting system..."

if command -v pacman &>/dev/null; then
  DISTRO="arch"
  ok "Arch Linux detected"
elif command -v apt-get &>/dev/null; then
  DISTRO="debian"
  ok "Debian/Ubuntu detected"
elif command -v dnf &>/dev/null; then
  DISTRO="fedora"
  ok "Fedora/RHEL detected"
else
  err "Unsupported distro. Install manually: libimobiledevice, python3, pip."
fi

# ── Ask backup location ───────────────────────────────────────────────────────
header "Backup location"
echo -e "${DIM}Where should Peach store your iOS backups?${NC}"
echo ""

DEFAULT_DIR="${REAL_HOME}/peach-backups"
read -rp "  Path [${DEFAULT_DIR}]: " BACKUP_DIR
BACKUP_DIR="${BACKUP_DIR:-$DEFAULT_DIR}"
BACKUP_DIR="${BACKUP_DIR/#\~/$REAL_HOME}"

log "Backups will be saved to: ${BOLD}${BACKUP_DIR}${NC}"
mkdir -p "$BACKUP_DIR"
ok "Backup directory ready"

# ── Install system dependencies ───────────────────────────────────────────────
header "Installing dependencies..."

if [[ "$DISTRO" == "arch" ]]; then
  pacman -Sy --noconfirm --needed libimobiledevice usbmuxd python python-pip python-virtualenv 2>&1 | \
    grep -E '(installing|upgrading|up to date)' | sed 's/^/  /' || true
  ok "Arch packages installed"
elif [[ "$DISTRO" == "debian" ]]; then
  apt-get update -qq
  apt-get install -y -qq libimobiledevice-utils usbmuxd python3 python3-pip python3-venv
  ok "Debian packages installed"
elif [[ "$DISTRO" == "fedora" ]]; then
  dnf install -y -q libimobiledevice libimobiledevice-utils usbmuxd python3 python3-pip
  ok "Fedora packages installed"
fi

command -v idevice_id    &>/dev/null || err "idevice_id not found. libimobiledevice may not have installed correctly."
command -v idevicebackup2 &>/dev/null || err "idevicebackup2 not found. libimobiledevice may not have installed correctly."
ok "libimobiledevice tools verified"

# ── Fetch latest release ──────────────────────────────────────────────────────
header "Fetching latest release..."

RELEASE_TAG=""
RELEASE_JSON=$(curl -fsSL --max-time 10 "$GITHUB_API" 2>/dev/null) && \
  RELEASE_TAG=$(echo "$RELEASE_JSON" | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/') || true

if [[ -n "$RELEASE_TAG" ]]; then
  ok "Latest release: ${BOLD}${RELEASE_TAG}${NC}"
  BASE_URL="https://raw.githubusercontent.com/${GITHUB_REPO}/refs/tags/${RELEASE_TAG}"
else
  log "Could not fetch release tag, installing from ${BOLD}main${NC}..."
  RELEASE_TAG="main"
  BASE_URL="https://raw.githubusercontent.com/${GITHUB_REPO}/main"
fi

# ── Download app files ────────────────────────────────────────────────────────
header "Downloading Peach ${RELEASE_TAG}..."

mkdir -p "${PEACH_DIR}/backend" "${PEACH_DIR}/ui"

download() {
  local url="$1" dest="$2"
  curl -fsSL "$url" -o "$dest" || err "Failed to download: $url"
}

download "${BASE_URL}/main.py"          "${PEACH_DIR}/backend/main.py"
download "${BASE_URL}/requirements.txt" "${PEACH_DIR}/backend/requirements.txt"
download "${BASE_URL}/index.html"            "${PEACH_DIR}/ui/index.html"
ok "App files downloaded to ${PEACH_DIR}"

# ── Python venv ───────────────────────────────────────────────────────────────
log "Setting up Python virtual environment..."
python3 -m venv "${PEACH_DIR}/venv"
"${PEACH_DIR}/venv/bin/pip" install -q -r "${PEACH_DIR}/backend/requirements.txt"
ok "Python environment ready"

# ── Write config ──────────────────────────────────────────────────────────────
mkdir -p "${CONFIG_DIR}"
cat > "${CONFIG_DIR}/config.json" <<EOF
{
  "backup_dir": "${BACKUP_DIR}"
}
EOF
ok "Config written to ${CONFIG_DIR}/config.json"

# ── udev rule ─────────────────────────────────────────────────────────────────
download "${BASE_URL}/99-peach-ios.rules" "${UDEV_RULE}"
udevadm control --reload-rules 2>/dev/null || true
ok "udev rule installed"

# ── systemd service ───────────────────────────────────────────────────────────
download "${BASE_URL}/peach.service" "${SERVICE_FILE}"

sed -i "s|User=%i|User=${REAL_USER}|g"                                  "${SERVICE_FILE}"
sed -i "s|/opt/peach/venv|${PEACH_DIR}/venv|g"                         "${SERVICE_FILE}"
sed -i "s|/opt/peach/backend|${PEACH_DIR}/backend|g"                   "${SERVICE_FILE}"
sed -i "s|WorkingDirectory=/opt/peach|WorkingDirectory=${PEACH_DIR}|g" "${SERVICE_FILE}"

systemctl daemon-reload
systemctl enable --now peach
ok "Peach service enabled and started"

# ── usbmuxd ───────────────────────────────────────────────────────────────────
if systemctl list-unit-files usbmuxd.service &>/dev/null; then
  systemctl enable --now usbmuxd 2>/dev/null || true
  ok "usbmuxd service enabled"
fi

# ── Done! ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "${PEACH}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}${BOLD}  🍑 Peach ${RELEASE_TAG} installed!${NC}"
echo -e "${PEACH}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  Open in your browser:"
echo -e "  ${BOLD}http://localhost:${PORT}${NC}"
echo ""
echo -e "${DIM}  Backups → ${BACKUP_DIR}${NC}"
echo -e "${DIM}  Config  → ${CONFIG_DIR}/config.json${NC}"
echo -e "${DIM}  Logs    → journalctl -u peach -f${NC}"
echo ""
echo -e "${DIM}  To plug in your iPhone:${NC}"
echo -e "${DIM}  1. Connect via USB${NC}"
echo -e "${DIM}  2. Tap 'Trust' on your device${NC}"
echo -e "${DIM}  3. Hit 'Back Up Now' in the UI${NC}"
echo ""
