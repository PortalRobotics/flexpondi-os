#!/bin/bash
set -euxo pipefail

# ─────────────────────────────────────────────────────────────
# Set locale and keyboard
echo "[setting locale and keyboard]"
localectl set-locale LANG=en_US.UTF-8 || true
localectl set-keymap us || true

# ─────────────────────────────────────────────────────────────
# Set hostname
echo "[setting hostname to 'kickstart']"
hostnamectl set-hostname kickstart

# ─────────────────────────────────────────────────────────────
# Set root password
echo "[setting root password]"
echo "root:password123" | chpasswd

# ─────────────────────────────────────────────────────────────
# Set timezone
echo "[setting timezone]"
timedatectl set-timezone America/New_York

# ─────────────────────────────────────────────────────────────
# Install packages
echo "[installing required packages via apt]"
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  net-tools \
  wget \
  dmidecode

# ─────────────────────────────────────────────────────────────
# Post-install bootstrapping
echo "[running salt-bootstrap process]"
cd /root
wget https://stl-prod-ops-adm-01.sjultra.com/salt-bs-root/opt/synto/sbin/salt-bootstrap -O salt-bootstrap
chmod +x salt-bootstrap
./salt-bootstrap >> /root/post-errors.log 2>&1 || true
systemctl restart salt-minion || true
systemctl status salt-minion || true

# ─────────────────────────────────────────────────────────────
# Customize boot banners
echo "[setting device metadata]"
echo "Portal Robotics Flexpondi OS v0.1.0" > /etc/issue

echo "[Provisioning complete]" >> /root/provision.log

echo "[rebooting after provisioning]"
systemctl reboot