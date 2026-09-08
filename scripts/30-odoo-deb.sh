#!/usr/bin/env bash
# 30-odoo-deb: official nightly deb, pinned and held.
# The deb provides: odoo system user, /var/lib/odoo, /etc/odoo/odoo.conf,
# /var/log/odoo, logrotate, base systemd unit, odoo in dist-packages.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
: "${ODOO_VERSION:=18.0}"

wget -q -O - https://nightly.odoo.com/odoo.key | gpg --dearmor -o /usr/share/keyrings/odoo-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/odoo-archive-keyring.gpg] https://nightly.odoo.com/${ODOO_VERSION}/nightly/deb/ ./" \
  > /etc/apt/sources.list.d/odoo.list
apt-get update -qq
apt-get install -y odoo

# Never let apt bump Odoo silently: upgrades are a maintenance-window op:
#   apt-mark unhold odoo && apt install odoo=<dated-build> && \
#   sudo -u odoo odoo -c /etc/odoo/odoo.conf -u all --stop-after-init
apt-mark hold odoo

# wkhtmltopdf (patched qt) for proper PDF reports: distro builds break
# headers/footers. Install Odoo's own build per-distro; see
# https://github.com/odoo/odoo/wiki/Wkhtmltopdf
