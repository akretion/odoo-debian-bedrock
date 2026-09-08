#!/usr/bin/env bash
# 10-base: host basics + unattended security upgrades.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get update -qq
apt-get install -y -qq wget curl gnupg ca-certificates lsb-release \
  unattended-upgrades fail2ban ufw

# Security upgrades for the OS only. The odoo deb is pinned/held in
# 30-odoo-deb.sh: unattended Odoo minor upgrades can require `-u all`
# and must stay a deliberate, backed-up operation.
cat > /etc/apt/apt.conf.d/51akretion-unattended <<'EOF'
Unattended-Upgrade::Allowed-Origins {
  "${distro_id}:${distro_codename}-security";
  "${distro_id}ESMApps:${distro_codename}-apps-security";
};
Unattended-Upgrade::Package-Blacklist { "odoo"; };
EOF
dpkg-reconfigure -f noninteractive unattended-upgrades || true

ufw allow OpenSSH
ufw allow 'Nginx Full'
ufw --force enable || true
