#!/bin/bash

# Exit immediately if any command fails
set -e

echo "===================================================="
echo " Starting Automated Pi-hole Production Installation "
echo "===================================================="

# 1. Privileged State & Environment Validation
if [ "$EUID" -ne 0 ]; then
  echo "[!] Critical Error: This script must be run as root (sudo)."
  exit 1
fi

if [ ! -f .env ]; then
  echo "[!] Configuration Missing: .env file not found."
  echo "[*] Creating .env from template. Please update your password inside it."
  cp .env.example .env
  exit 1
fi

# 2. Hardening Host SSH State
echo "[*] Ensuring SSH service is permanently active and enabled..."
systemctl enable ssh
systemctl start ssh

echo "[*] Updating core system package indexes..."
apt-get update -y

# 3. Streamlined Idempotent Docker Engine Deployment
if ! command -v docker &> /dev/null; then
    echo "[*] Deploying Docker Engine core via official utility script..."
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh
    rm get-docker.sh
else
    echo "[*] Docker engine runtime already identified. Skipping install."
fi

# 4. Engine Boot Persistence Hooking
echo "[*] Ensuring systemd automatically triggers Docker on system boot..."
systemctl enable docker
systemctl enable containerd

# 5. Network Mirror Loop Prevention
echo "[*] Temporarily shifting host DNS mapping to avoid upstream pull failures..."
cp /etc/resolv.conf /etc/resolv.conf.bak
echo "nameserver 1.1.1.1" > /etc/resolv.conf

# 6. Build Orchestration
echo "[*] Forging persistence mount paths..."
mkdir -p etc-pihole

echo "[*] Activating deployment composition via Docker Daemon..."
docker compose pull
docker compose up -d --remove-orphans

# Restore default network tracking matrices
mv /etc/resolv.conf.bak /etc/resolv.conf

echo "===================================================="
echo " Infrastructure Deployment Finalized Successfully   "
echo "===================================================="
echo "[*] Process Completed."
echo "[*] Dashboard Interface accessible via: http://<PI_IP>/admin"