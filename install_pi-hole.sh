#!/bin/bash

# Exit immediately if any command fails
set -e

echo "===================================================="
echo " Starting Automated Pi-hole Production Installation "
echo "===================================================="

# 1. System Guardrails & Superuser Validation
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

# 2. Host System Optimization & SSH Persistence Enforcement
echo "[*] Ensuring SSH service is permanently enabled..."
systemctl enable ssh
systemctl start ssh

echo "[*] Updating core system package definitions..."
apt-get update -y

# 3. Idempotent Docker Runtime Installation
if ! command -v docker &> /dev/null; then
    echo "[*] Installing Docker Engine via official deployment channels..."
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh
    rm get-docker.sh
else
    echo "[*] Docker Engine already present on host. Skipping install."
fi

# Ensure Docker utilities are available
apt-get install -y docker-compose-v2

# 4. Persistence Configuration (Boot-level runtime preservation)
echo "[*] Enabling systemd hooks for Docker runtimes..."
systemctl enable docker
systemctl enable containerd

# 5. Network Loop Deadlock Prevention
echo "[*] Temporarily overriding local nameserver hooks to safely pull imagery..."
# Back up existing resolution profiles
cp /etc/resolv.conf /etc/resolv.conf.bak
echo "nameserver 1.1.1.1" > /etc/resolv.conf

# 6. Container Provisioning Phase
echo "[*] Creating structural storage volumes..."
mkdir -p etc-pihole etc-dnsmasq.d

echo "[*] Initiating orchestration via Docker Compose..."
docker compose pull
docker compose up -d --remove-orphans

# Restore original system network lookup matrix
mv /etc/resolv.conf.bak /etc/resolv.conf

echo "===================================================="
echo " Infrastructure Deployment Finalized Successfully   "
echo "===================================================="
echo "[*] Process Completed."
echo "[*] Dashboard Interface accessible via: http://<PI_IP>/admin"