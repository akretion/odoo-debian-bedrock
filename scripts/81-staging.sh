#!/usr/bin/env bash
# 81-staging: create a staging INSTANCE on a bedrock host that already has
# prod (the deb + prod venv) installed. The instance gets its own:
#   - deploy user app-<name>      (SSH/git access, own code clone/branch)
#   - runtime user odoo-<name>    (systemd User; peer-auth maps to PG role)
#   - PG role odoo-<name>         (separate databases)
#   - venv /usr/lib/odoo/venv-<name>  (independent odoo-addon versions)
#   - config /etc/odoo/odoo-<name>.conf (own db_user/dbfilter/ports)
#   - systemd unit odoo-<name>.service
# Shares only the Odoo core deb (/usr/lib/python3/dist-packages/odoo).
#
#   PROJECT_NAME=acme PROJECT_REPO=git@github.com:akretion/acme.git \
#     PROJECT_BRANCH=staging STAGING_NAME=staging \
#     STAGING_DOMAIN=staging.acme.example.com bash scripts/81-staging.sh
#
# If staging must run a DIFFERENT Odoo core version/branch, add a source
# clone dir to addons_path in /etc/odoo/odoo-<name>.conf and point the unit
# at its odoo-bin — out of scope for this helper.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
: "${ODOO_VERSION:=18.0}"
: "${PROJECT_NAME:?set PROJECT_NAME}"
: "${PROJECT_REPO:?set PROJECT_REPO (git url)}"
: "${PROJECT_BRANCH:=}"

NAME="${STAGING_NAME:-staging}"
APP_USER="app-$NAME"
RUNTIME_USER="odoo-$NAME"
VENV="/usr/lib/odoo/venv-$NAME"
ODOO_CONF="/etc/odoo/odoo-$NAME.conf"
DB_USER="odoo-$NAME"
DBFILTER="^${PROJECT_NAME}_${NAME}.*"
UNIT="odoo-$NAME"
LOG_DIR="/var/log/odoo-$NAME"
HTTP_PORT="${STAGING_HTTP_PORT:-8070}"
LONGPOLLING_PORT="${STAGING_LONGPOLLING_PORT:-8073}"
STAGING_DOMAIN="${STAGING_DOMAIN:-}"

# shellcheck source=lib-instance.sh
source "$(dirname "$0")/lib-instance.sh"

# Runtime user (system user, like the deb's `odoo`) — peer auth maps it
# to the PG role of the same name, giving a separate DB user "for free".
id "$RUNTIME_USER" &>/dev/null || adduser --system --group --home "/var/lib/$RUNTIME_USER" "$RUNTIME_USER"
# Deploy user: grant SSH keys here for devs who may deploy staging but not prod.
id "$APP_USER" &>/dev/null || adduser --disabled-password --gecos "" "$APP_USER"
# Separate PG role (needs a running postgres; guard for proot/container).
su - postgres -c "psql -tAc \"SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'\" | grep -q 1 || createuser -d -R -S $DB_USER" 2>/dev/null || true
install -d -o "$RUNTIME_USER" -g "$RUNTIME_USER" "$LOG_DIR"

make_venv
VENV_ADDONS=$(venv_addons_dir)

sed -e "s|@ADMIN_PASSWD@|${ODOO_ADMIN_PASSWD:-admin}|" \
    -e "s|@VENV_ADDONS@|$VENV_ADDONS|" \
    -e "s|@DB_USER@|$DB_USER|" \
    -e "s|@DBFILTER@|$DBFILTER|" \
    -e "s|@HTTP_PORT@|$HTTP_PORT|" \
    -e "s|@LONGPOLLING_PORT@|$LONGPOLLING_PORT|" \
    "$BEDROCK_DIR/templates/odoo-instance.conf" > "$ODOO_CONF"
chown "$RUNTIME_USER":"$RUNTIME_USER" "$ODOO_CONF"
chmod 0640 "$ODOO_CONF"

sed -e "s|@NAME@|$NAME|" -e "s|@RUNTIME_USER@|$RUNTIME_USER|" \
    -e "s|@VENV@|$VENV|" -e "s|@CONF@|$ODOO_CONF|" -e "s|@LOG_DIR@|$LOG_DIR|" \
    "$BEDROCK_DIR/templates/odoo-instance.service" > "/etc/systemd/system/$UNIT.service"

# Clone/branch, requirements -> staging venv, addons_path + dbfilter.
attach_project

if [ -n "$STAGING_DOMAIN" ]; then
  WS_PATH=/websocket
  case "$ODOO_VERSION" in 8.*|9.*|1[0-5].*) WS_PATH=/longpolling/ ;; esac
  render_nginx "$STAGING_DOMAIN" "$WS_PATH" "$HTTP_PORT" "$LONGPOLLING_PORT" \
    "/etc/nginx/sites-available/odoo-$NAME"
  ln -sf "/etc/nginx/sites-available/odoo-$NAME" "/etc/nginx/sites-enabled/odoo-$NAME"
  nginx -t 2>/dev/null && (nginx -s reload 2>/dev/null || true) || true
fi

systemctl daemon-reload 2>/dev/null || true
systemctl enable "$UNIT" 2>/dev/null || true
systemctl restart "$UNIT" 2>/dev/null || \
  echo "no systemd here — run: $VENV/bin/python3 /usr/bin/odoo -c $ODOO_CONF"
echo "staging '$NAME' ready: deploy=$APP_USER runtime=$RUNTIME_USER db=$DB_USER port=$HTTP_PORT conf=$ODOO_CONF"
