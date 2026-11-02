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
  # Pin every unpinned odoo-addon-* to the target series. Unpinned specs make
  # pip backtrack through 19.0/20.0 wheels of the same addon (OCA publishes
  # no PEP 658 metadata, so pip downloads whole 8 MB wheels) before settling
  # on $ODOO_VERSION: minutes of wrong-series downloads for every addon.
  # An explicit constraint in OCA_ADDONS is always preserved.
  _pinned=""
  for _spec in $OCA_ADDONS; do
    case "$_spec" in
      *==*|*'<'*|*'>'*|*'~='*|*'['*|*'@'*) _pinned="$_pinned $_spec" ;;
      *) _pinned="$_pinned ${_spec}==${ODOO_VERSION}.*" ;;
    esac
  done
  # shellcheck disable=SC2086
  "$VENV/bin/pip" install $_pinned
fi

# NOTE: running module tests additionally needs test-only deps that
# odoo-addon-* doesn't declare, e.g.: pip install xmldiff vcrpy

VENV_ADDONS=$(venv_addons_dir)

sed -e "s|@ADMIN_PASSWD@|${ODOO_ADMIN_PASSWD:-admin}|" \
    -e "s|@VENV_ADDONS@|$VENV_ADDONS|" \
    -e "s|@HTTP_PORT@|${ODOO_PORT:-8069}|" \
    -e "s|@LONGPOLLING_PORT@|${LONGPOLLING_PORT:-8072}|" \
    -e "s|@HTTP_INTERFACE@|${HTTP_INTERFACE:-127.0.0.1}|" \
    "$BEDROCK_DIR/templates/odoo.conf" > /etc/odoo/odoo.conf
chown "$RUNTIME_USER":"$RUNTIME_USER" /etc/odoo/odoo.conf
chmod 0640 /etc/odoo/odoo.conf

# Run Odoo through the venv interpreter + systemd hardening (drop-in on
# the deb's own odoo.service):
install -d /etc/systemd/system/odoo.service.d
sed "s|@VENV@|$VENV|" "$BEDROCK_DIR/templates/systemd-override.conf" \
  > /etc/systemd/system/odoo.service.d/akretion.conf
systemctl daemon-reload 2>/dev/null || true   # no systemd under proot/tests
