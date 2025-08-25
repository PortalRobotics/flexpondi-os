#!/bin/bash
# set -euxo pipefail

# ─────────────────────────────────────────────────────────────
# Set locale and keyboard
localectl set-locale LANG=en_US.UTF-8
localectl set-keymap us

# ─────────────────────────────────────────────────────────────
# Set hostname and ensure DHCP
hostnamectl set-hostname kickstart

# ─────────────────────────────────────────────────────────────
# Set root password (plaintext)
echo "root:password123" | chpasswd

# ─────────────────────────────────────────────────────────────
# Set timezone
timedatectl set-timezone America/New_York

# ─────────────────────────────────────────────────────────────
# Disable SELinux
sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config
setenforce 0 || true

# ─────────────────────────────────────────────────────────────
# Install packages
dnf install -y \
  @core \
  @standard \
  net-tools \
  wget \
  dmidecode

# ─────────────────────────────────────────────────────────────
# Post-install bootstrapping
cd /root
wget https://stl-prod-ops-adm-01.sjultra.com/salt-bs-root/opt/synto/sbin/salt-bootstrap -O salt-bootstrap
chmod +x salt-bootstrap
./salt-bootstrap >> /root/post-errors.log 2>&1 || true
systemctl restart salt-minion || true
systemctl status salt-minion || true

# ─────────────────────────────────────────────────────────────
# Customize boot banners
UUID=$(dmidecode -s system-uuid || echo "unknown")
rm -f /etc/issue.d/cockpit.issue
echo "Portal Robotics Flexpondi OS v0.1.0" > /etc/issue
echo "UUID: $UUID" > /etc/issue.d/uuid.issue

# ─────────────────────────────────────────────────────────────
# Reboot (or systemd will do it after)
echo "Provisioning complete" >> /root/provision.log
systemctl disable firstboot.service