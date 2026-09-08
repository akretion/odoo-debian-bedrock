#!/usr/bin/env bash
# 40-oca-venv: the PROD instance venv + hardened config + systemd drop-in.
# Uses lib-instance.sh so staging (81-staging.sh) gets the same venv recipe.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
: "${ODOO_VERSION:=18.0}"
: "${OCA_ADDONS:=}"

VENV=/usr/lib/odoo/venv
RUNTIME_USER=odoo
# shellcheck source=lib-instance.sh
source "$(dirname "$0")/lib-instance.sh"

make_venv

if [ -n "$OCA_ADDONS" ]; then
  # shellcheck disable=SC2086
  "$VENV/bin/pip" install $OCA_ADDONS
fi

# NOTE: running module tests additionally needs test-only deps that
# odoo-addon-* doesn't declare, e.g.: pip install xmldiff vcrpy

VENV_ADDONS=$(venv_addons_dir)

sed -e "s|@ADMIN_PASSWD@|${ODOO_ADMIN_PASSWD:-admin}|" \
    -e "s|@VENV_ADDONS@|$VENV_ADDONS|" \
    "$BEDROCK_DIR/templates/odoo.conf" > /etc/odoo/odoo.conf
chown "$RUNTIME_USER":"$RUNTIME_USER" /etc/odoo/odoo.conf
chmod 0640 /etc/odoo/odoo.conf

# Run Odoo through the venv interpreter + systemd hardening (drop-in on
# the deb's own odoo.service):
install -d /etc/systemd/system/odoo.service.d
sed "s|@VENV@|$VENV|" "$BEDROCK_DIR/templates/systemd-override.conf" \
  > /etc/systemd/system/odoo.service.d/akretion.conf
systemctl daemon-reload 2>/dev/null || true   # no systemd under proot/tests
