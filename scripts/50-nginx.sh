#!/usr/bin/env bash
# 50-nginx: reverse proxy vhost + optional Let's Encrypt via certbot.
# Set DOMAIN to enable; skips otherwise. Set CERTBOT_EMAIL for
# unattended certificate issuance.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
: "${DOMAIN:=}"
: "${ODOO_VERSION:=18.0}"
: "${CERTBOT_EMAIL:=}"

# shellcheck source=lib-instance.sh
source "$(dirname "$0")/lib-instance.sh"

[ -z "$DOMAIN" ] && { echo "DOMAIN not set, skipping nginx."; exit 0; }

apt-get install -y -qq nginx certbot python3-certbot-nginx

# /websocket (Odoo >= 16) vs /longpolling/ (Odoo <= 15), same longpolling port.
WS_PATH=/websocket
case "$ODOO_VERSION" in
  8.*|9.*|1[0-5].*) WS_PATH=/longpolling/ ;;
esac

render_nginx "$DOMAIN" "$WS_PATH" "${ODOO_PORT:-8069}" "${LONGPOLLING_PORT:-8072}" \
  /etc/nginx/sites-available/odoo
ln -sf /etc/nginx/sites-available/odoo /etc/nginx/sites-enabled/odoo

# nginx config check; then reload a running master, or start one
# (containers have no systemd/service, so plain `nginx` daemonizes).
nginx -t
if [ -f /run/nginx.pid ] && kill -0 "$(cat /run/nginx.pid)" 2>/dev/null; then
  nginx -s reload
else
  nginx
fi

if [ -n "$CERTBOT_EMAIL" ]; then
  certbot --nginx -d "$DOMAIN" -m "$CERTBOT_EMAIL" --agree-tos -n --redirect
  nginx -s reload 2>/dev/null || systemctl reload nginx 2>/dev/null || true
else
  echo "nginx vhost installed for $DOMAIN."
  echo "For HTTPS: certbot --nginx -d $DOMAIN  (or set CERTBOT_EMAIL and re-run for unattended issuance)"
fi
