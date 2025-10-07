#!/bin/bash
set -euxo pipefail

# ─────────────────────────────────────────────────────────────
# Set locale and keyboard
echo "[setting locale and keyboard]"
localectl set-locale LANG=en_US.UTF-8
localectl set-keymap us

# ─────────────────────────────────────────────────────────────
# Set hostname
echo "[setting hostname to 'kickstart']"
hostnamectl set-hostname kickstart

# ─────────────────────────────────────────────────────────────
# Set root password (plaintext)
echo "[setting root password]"
echo "root:password123" | chpasswd

# ─────────────────────────────────────────────────────────────
# Set timezone
echo "[setting timezone]"
timedatectl set-timezone America/New_York

# ─────────────────────────────────────────────────────────────
# Disable SELinux
echo "[disabling SELINUX]"
sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config
setenforce 0 || true

echo "[growing partition to use all available physical storage]"
rootfs-expand

# ─────────────────────────────────────────────────────────────
# Install packages
echo "[installing required packages via dnf]"
dnf install -y \
  @core \
  @standard \
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
UUID=$(dmidecode -s system-uuid || echo "unknown")
rm -f /etc/issue.d/cockpit.issue
echo "Portal Robotics Flexpondi OS v0.1.0" > /etc/issue
echo "UUID: $UUID" > /etc/issue.d/uuid.issue

# ─────────────────────────────────────────────────────────────
# Reboot (or systemd will do it after)
echo "[firstboot.sh DONE]"
echo "Provisioning complete" >> /root/provision.log
systemctl disable firstboot.service