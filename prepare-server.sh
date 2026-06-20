#!/usr/bin/env bash
set -Eeuo pipefail

log() {
  echo "[+] $*"
}

warn() {
  echo "[!] $*" >&2
}

strip_cr() {
  printf '%s' "$1" | tr -d '\r'
}

die() {
  echo "[x] $*" >&2
  exit 1
}

backup_file() {
  local f="$1"
  [[ -f "$f" ]] && cp -a "$f" "${f}.bak.$(date +%F-%H%M%S)"
}

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "Run this script as root"
}

set_sshd_option() {
  local key="$1"
  local value="$2"
  local file="$3"

  if grep -Eq "^[#[:space:]]*${key}[[:space:]]+" "$file"; then
    sed -ri "s|^[#[:space:]]*${key}[[:space:]]+.*|${key} ${value}|g" "$file"
  else
    echo "${key} ${value}" >> "$file"
  fi
}

prompt_input() {
  local prompt="$1"
  local default="$2"
  local input=""
  
  if [[ -n "$default" ]]; then
    read -p "$prompt [$default]: " input
    echo "${input:-$default}"
  else
    while [[ -z "$input" ]]; do
      read -p "$prompt: " input
    done
    echo "$input"
  fi
}

prompt_password() {
  local prompt="$1"
  local password=""
  local password_confirm=""
  
  while true; do
    read -s -p "$prompt: " password
    echo
    read -s -p "Confirm password: " password_confirm
    echo
    
    if [[ "$password" == "$password_confirm" ]]; then
      echo "$password"
      return 0
    else
      warn "Passwords do not match. Try again."
    fi
  done
}

require_root

echo "========================================"
echo "Server Preparation Script"
echo "========================================"
echo

# Get user input
log "Please provide the following information:"
echo

NEW_USERNAME=$(prompt_input "New username for SSH access" "deploy")
NEW_USERNAME="$(strip_cr "$NEW_USERNAME")"

SSH_PORT=$(prompt_input "SSH port" "2091")
SSH_PORT="$(strip_cr "$SSH_PORT")"

SERVER_IP=$(prompt_input "Server IP (optional)" "")
SERVER_IP="$(strip_cr "$SERVER_IP")"

NEW_PASSWORD=$(prompt_password "Password for $NEW_USERNAME")
NEW_PASSWORD="$(strip_cr "$NEW_PASSWORD")"

echo
log "Configuration:"
echo "  Username: $NEW_USERNAME"
echo "  SSH Port: $SSH_PORT"
echo "  Server IP: ${SERVER_IP:-(will be detected)}"
echo

read -p "Continue with this configuration? (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  die "Aborted by user"
fi

# Validate inputs
: "${NEW_USERNAME:?Missing NEW_USERNAME}"
: "${SSH_PORT:=2091}"
: "${NEW_PASSWORD:?Missing password}"

# Detect external IP
EXTERNAL_IP=$(curl -s -4 --max-time 10 ipv4.icanhazip.com 2>/dev/null || curl -s -4 --max-time 10 ifconfig.me 2>/dev/null || echo "")
if [[ -n "$EXTERNAL_IP" ]]; then
  log "External IP detected: ${EXTERNAL_IP}"
else
  EXTERNAL_IP="${SERVER_IP:-$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n1)}"
  warn "Could not detect external IP; using: ${EXTERNAL_IP}"
fi

export DEBIAN_FRONTEND=noninteractive

log "Installing required packages"
apt-get update
apt-get install -y sudo ufw fail2ban curl ca-certificates openssh-server libpam-modules logrotate

if id "$NEW_USERNAME" >/dev/null 2>&1; then
  log "User $NEW_USERNAME already exists"
else
  log "Creating user $NEW_USERNAME"
  useradd -m -s /bin/bash "$NEW_USERNAME"
fi

log "Setting password for $NEW_USERNAME"
printf '%s:%s\n' "$NEW_USERNAME" "$NEW_PASSWORD" | chpasswd

log "Adding $NEW_USERNAME to sudo group"
usermod -aG sudo "$NEW_USERNAME"

log "Configuring passwordless sudo for $NEW_USERNAME"
SUDOERS_FILE="/etc/sudoers.d/${NEW_USERNAME}"
printf '%s\n' "${NEW_USERNAME} ALL=(ALL:ALL) NOPASSWD:ALL" > "$SUDOERS_FILE"
chmod 440 "$SUDOERS_FILE"
visudo -cf "$SUDOERS_FILE" >/dev/null || die "sudoers validation failed for $SUDOERS_FILE"

install -d -m 700 -o "$NEW_USERNAME" -g "$NEW_USERNAME" "/home/$NEW_USERNAME/.ssh"

SSHD_CONFIG="/etc/ssh/sshd_config"
backup_file "$SSHD_CONFIG"

log "Configuring SSH"
set_sshd_option "Port" "$SSH_PORT" "$SSHD_CONFIG"
set_sshd_option "PermitRootLogin" "no" "$SSHD_CONFIG"
set_sshd_option "PasswordAuthentication" "yes" "$SSHD_CONFIG"
set_sshd_option "PubkeyAuthentication" "yes" "$SSHD_CONFIG"
set_sshd_option "ChallengeResponseAuthentication" "no" "$SSHD_CONFIG"
set_sshd_option "UsePAM" "yes" "$SSHD_CONFIG"
mkdir -p /run/sshd
chmod 755 /run/sshd

log "Validating sshd config"
sshd -t || die "sshd config test failed"

log "Configuring UFW"
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow "${SSH_PORT}/tcp"
ufw --force enable

log "Configuring fail2ban"
mkdir -p /etc/fail2ban
cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5
backend = systemd
banaction = ufw

[sshd]
enabled = true
port = ${SSH_PORT}
logpath = %(sshd_log)s
EOF

systemctl enable fail2ban
systemctl restart fail2ban

log "Restarting SSH service"

SSH_SERVICE=""
for svc in ssh sshd; do
  if systemctl cat "$svc" >/dev/null 2>&1; then
    SSH_SERVICE="$svc"
    break
  fi
done

if [[ -n "$SSH_SERVICE" ]]; then
  systemctl restart "$SSH_SERVICE"
  systemctl enable "$SSH_SERVICE" >/dev/null 2>&1 || true
else
  warn "SSH unit not found via systemctl, trying service command"
  if service ssh status >/dev/null 2>&1; then
    service ssh restart
  elif service sshd status >/dev/null 2>&1; then
    service sshd restart
  else
    die "SSH service not found"
  fi
fi

log "Final checks"
fail2ban-client status sshd || warn "fail2ban sshd status check failed"
ufw status verbose || warn "ufw status check failed"

echo
echo "Done."
echo "New SSH port: ${SSH_PORT}"
echo "User with sudo: ${NEW_USERNAME}"
echo
echo "IMPORTANT:"
echo "1. Open a NEW terminal before closing the current session."
echo "2. Test login: ssh -p ${SSH_PORT} ${NEW_USERNAME}@${EXTERNAL_IP:-<unknown>}"
echo "3. Test sudo after login: sudo -v"
echo "4. Only after successful login close the current root session."
