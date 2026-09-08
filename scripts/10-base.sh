#!/usr/bin/env bash
# 10-base: host basics + unattended security upgrades.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get update -qq
apt-get install -y -qq wget curl gnupg ca-certificates lsb-release \
  unattended-upgrades fail2ban ufw locales gettext-base

# UTF-8 locale (acsone/odoo-bedrock sets LANG=C.UTF-8 for the same reason;
# Odoo misbehaves on sorting/encoding without it)
sed -i 's/^# *\(en_US.UTF-8 UTF-8\)/\1/' /etc/locale.gen 2>/dev/null || true
locale-gen > /dev/null 2>&1 || true
update-locale LANG=C.UTF-8 LC_ALL=C.UTF-8 || true

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
